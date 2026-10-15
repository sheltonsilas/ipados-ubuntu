import Foundation
import UbuntuPadCore
import UbuntuPadHost

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Loads a static AArch64 Linux ELF and runs it on the host CPU.
///
/// This is Track B's engine room, and it is a **library** rather than part of the command-line tool
/// so that the iOS app runs exactly the code CI tests: `ubuntupad-run` and `UbuntuPad.app` both link
/// this target and neither owns a second copy of the sequence below. The CLI adds argument parsing
/// and machine-readable output; the app adds a button.
///
/// The sequence is the whole design in one place:
///
/// 1. parse the image and plan the patch that turns every Linux `svc #0` into a breakpoint;
/// 2. decide *where* the image can live on this host (`ImagePlacement`) — this is where the platform's
///    reserved low memory is dealt with, by moving the image rather than by fighting the kernel;
/// 3. apply the image's own relative relocations, in the file bytes, so the picture-independent image
///    becomes correct for the base it is about to be mapped at;
/// 4. map the image at `bias + link-time address` (identity mapping — a guest address *is* a host
///    address, which is what makes guest pointers safe to dereference in the syscall services);
/// 5. write the patched image and the Linux initial stack (argc/argv/envp/auxv) into it;
/// 6. protect each host page according to the plan — read-only text stays read-only, and on a 16 KiB
///    host two guest segments sharing a page get the union of their rights;
/// 7. install the trap handler and branch to the entry point. Every syscall then arrives in Swift.
///
/// Nothing here writes an executable mapping: the text is written while it is writable and made
/// executable afterwards, so there is never a writable-and-executable page. See
/// docs/RESEARCH/jit-and-entitlements-on-ios.md for why that matters on a non-jailbroken device.
public final class GuestRunner {
    public struct Options {
        public var executablePath: String
        public var arguments: [String]
        public var environment: [String]
        public var stackSize: Int
        public var verbose: Bool
        /// Test-only escape hatch: run without the relocation pass, so CI can show that a
        /// position-independent guest *needs* it (the run then faults instead of printing its message).
        public var skipRelocations: Bool

        public init(
            executablePath: String,
            arguments: [String],
            environment: [String],
            stackSize: Int = 1 << 20,
            verbose: Bool = false,
            skipRelocations: Bool = false
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.stackSize = stackSize
            self.verbose = verbose
            self.skipRelocations = skipRelocations
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        case cannotReadImage(String)
        case cannotRunOnThisHost(reason: String)
        case relocationFailed(String)
        case unsupportedRelocations(types: [UInt32])
        case cannotMapImage(address: UInt64, length: UInt64, landedAt: UInt64, errno: Int32)
        case cannotMapImageAtAnyBias(attempts: [String])
        case cannotMapStack
        case segmentOutsideImage(name: String)
        case protectionFailed(address: UInt64, length: UInt64)

        public var description: String {
            switch self {
            case let .cannotReadImage(description):
                return "cannot read the guest image: \(description)"
            case let .cannotRunOnThisHost(reason):
                return "this image cannot run on this host. \(reason)"
            case let .relocationFailed(detail):
                return "the image's relative relocations could not be applied: \(detail)"
            case let .unsupportedRelocations(types):
                return
                    "the image needs relocation types \(types.map(String.init).joined(separator: ", ")) that this runtime does not implement. Applying some relocations and not others would produce a program that looks alive and reads garbage, so the runtime refuses instead; symbol-based relocations belong with the dynamic linker (Phase 4)."
            case let .cannotMapImage(address, length, landedAt, errorNumber):
                return
                    "cannot map the guest image at 0x\(String(address, radix: 16)) (0x\(String(length, radix: 16)) bytes, errno \(errorNumber))\(landedAt == 0 ? "" : "; the kernel offered 0x\(String(landedAt, radix: 16))"). A guest address must be a host address, so the runtime refuses to continue rather than run the image somewhere its own pointers do not point."
            case let .cannotMapImageAtAnyBias(attempts):
                return
                    "no address this host would honour produced a valid mapping. Every attempt is listed, because each one is a fact about the address space: \(attempts.joined(separator: "; ")). A guest address must be a host address, so running the image somewhere else is not an option."
            case .cannotMapStack:
                return "cannot reserve the guest stack"
            case let .segmentOutsideImage(name):
                return "segment \(name) extends past the end of the image file"
            case let .protectionFailed(address, length):
                return
                    "mprotect failed for 0x\(String(address, radix: 16))+0x\(String(length, radix: 16))"
            }
        }
    }

    /// Everything a caller needs to report what happened. Public because the app shows these facts to
    /// the owner and CI asserts them, and both go through this one type.
    public struct Result {
        public var reason: String
        public var exitStatus: Int32
        public var syscallCount: Int
        public var patchedSites: Int
        public var placement: String
        public var bias: UInt64
        public var relativeRelocations: Int
        public var faultSignal: Int32
        public var faultAddress: UInt64
        public var trapPC: UInt64
        public var protectionPages: Int
        public var mergedProtectionPages: Int
        public var addressSpaceReport: String
        public var traceSummary: String
        public var unimplemented: [Int32]
    }

    private let options: Options
    private let emit: (String) -> Void

    public init(options: Options, emit: @escaping (String) -> Void) {
        self.options = options
        self.emit = emit
    }

    public func run() throws -> Result {
        guard up_can_run_guest() != 0 else {
            throw RunError.cannotRunOnThisHost(reason: "this CPU cannot execute AArch64 guest code")
        }

        let hostPageSize = Int(up_page_size())
        guard let geometry = PageGeometry(guestPageSize: 4096, hostPageSize: hostPageSize) else {
            throw GuestMemoryError.invalidGeometry
        }
        emit("host_page_size=\(hostPageSize) guest_page_size=\(geometry.guestPageSize)")

        // --- 1. the image
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: options.executablePath))
        } catch {
            throw RunError.cannotReadImage("\(error)")
        }
        let image = try ELFImage.parse(bytes)
        if let interpreter = image.interpreterPath(in: bytes) {
            // Honest failure: the dynamic loader is Phase 4 work, and pretending otherwise would
            // produce a confusing crash inside the guest instead.
            throw RunError.cannotReadImage(
                "this is a dynamically linked binary (PT_INTERP = \(interpreter)); only static executables run today")
        }
        emit(
            "elf=\(options.executablePath) entry=0x\(String(image.header.entryPoint, radix: 16)) load_segments=\(image.loadSegments.count) phnum=\(image.header.programHeaderCount)"
        )

        let plan = try PatchPlanner().plan(image: image, bytes: bytes)

        // The relocation table is read from the file now and applied once the base is known, because on
        // this host the base is not known until the mapping actually lands (see `mapImage`).
        var relocationTable: RelocationTable?
        if let dynamic = try DynamicSection.parse(image: image, bytes: bytes) {
            var table = RelocationTable()
            try table.parse(dynamic: dynamic, image: image, bytes: bytes)
            if table.unsupportedCount > 0 {
                throw RunError.unsupportedRelocations(types: table.unsupported.map { $0.type })
            }
            relocationTable = table
        }

        // --- 2. where can this image live on this host?
        //
        // On Apple silicon the answer is never "at its link-time addresses" for a normal Linux
        // executable: the low 4 GiB is `__PAGEZERO`, reserved by the kernel for every arm64 process.
        // The planner decides between identity, a bias, and an honest refusal, and it is a pure
        // function of the image plus the platform, so Linux CI can test every branch of it.
        let reservedLowRegion = up_reserved_low_region_size()
        let placement = try ImagePlacementPlanner().plan(
            image: image, reservedLowRegion: reservedLowRegion)
        if case let .refused(reason) = placement {
            throw RunError.cannotRunOnThisHost(reason: reason)
        }
        emit(
            "image_placement=\(placement.bias == 0 ? "identity" : "biased") requested_bias=0x\(String(placement.bias, radix: 16)) reserved_low_region_bytes=\(reservedLowRegion)"
        )

        // --- 3. map the image where it can live, and learn where that turned out to be
        //
        // The mapping decides the base, not the other way round: the host may not honour the requested
        // address, and a guest address must be a host address, so an image whose requested base is taken
        // is placed at the next candidate instead of somewhere arbitrary.
        let mapping = try mapImage(image: image, placement: placement, geometry: geometry)
        let bias = mapping.bias
        emit(
            "image_mapping=\(mapping.mechanism) bias=0x\(String(bias, radix: 16)) span=0x\(String(mapping.lowest, radix: 16))-0x\(String(mapping.highest, radix: 16))"
        )

        // --- 4. make the image correct for that base by applying its own relocations
        var relocatedImage = plan.patchedImage
        var relativeRelocations = 0
        if let table = relocationTable {
            if !options.skipRelocations {
                do {
                    relativeRelocations = try table.apply(to: &relocatedImage, image: image, bias: bias)
                } catch let error as RelocationError {
                    throw RunError.relocationFailed(error.description)
                }
            }
            emit(
                "relative_relocations=\(table.relativeCount) applied=\(options.skipRelocations ? 0 : relativeRelocations)\(options.skipRelocations && table.relativeCount > 0 ? " (skipped on request: this run is deliberately unrelocated)" : "")"
            )
        } else {
            // A static, non-PIE image has no dynamic section; the refusal above already covers the case
            // where such an image cannot be mapped, so reaching here means identity mapping is fine.
            emit("relative_relocations=none (the image has no PT_DYNAMIC segment)")
        }

        let loadSegments = image.loadSegments
        let lowest = mapping.lowest
        let highest = mapping.highest

        var space = GuestAddressSpace(geometry: geometry)

        // --- 5a. the image contents
        for segment in loadSegments {
            let name = "PT_LOAD[\(segment.index)]"
            let end = Int(segment.fileOffset + segment.fileSize)
            guard end <= relocatedImage.count else { throw RunError.segmentOutsideImage(name: name) }
            let guestAddress = segment.virtualAddress + bias
            let destination = UnsafeMutableRawPointer(bitPattern: UInt(guestAddress))
            guard let destination else { throw RunError.segmentOutsideImage(name: name) }
            if segment.fileSize > 0 {
                relocatedImage.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    destination.copyMemory(
                        from: base.advanced(by: Int(segment.fileOffset)), byteCount: Int(segment.fileSize))
                }
            }
            if segment.memorySize > segment.fileSize {
                // .bss: the ELF guarantees zeroes, and the mapping is anonymous memory, so only an
                // image reused from a previous run could carry stale bytes. It cannot here, but the
                // memset keeps that guarantee local and obvious.
                memset(
                    destination.advanced(by: Int(segment.fileSize)), 0,
                    Int(segment.memorySize - segment.fileSize))
            }
            try space.map(
                name: name,
                guestRange: guestAddress..<(guestAddress + segment.memorySize),
                protection: GuestProtection(elfFlags: segment.flags))
        }

        // --- 5b. the stack, then the Linux initial stack image inside it
        var stackAddress: UInt64 = 0
        guard up_reserve(0, options.stackSize, Int32(UP_RESERVE_HINT), &stackAddress) != nil else {
            throw RunError.cannotMapStack
        }
        try space.map(
            name: "stack",
            guestRange: stackAddress..<(stackAddress + UInt64(options.stackSize)),
            protection: .readWrite)

        // The guest must be told where its program header table and entry point *are*, which is the
        // bias-shifted address — the same value the trap handler will see in the program counter.
        let entryPoint = image.header.entryPoint + bias
        let layout = try InitialStackBuilder(
            geometry: geometry,
            stackTop: stackAddress + UInt64(options.stackSize),
            arguments: options.arguments,
            environment: options.environment,
            image: image,
            loadBias: bias,
            executablePath: options.executablePath,
            randomBytes: randomBytes(count: 16),
            hardwareCapabilities: 0x1f,
            executableAddress: entryPoint
        ).build()
        if let destination = UnsafeMutableRawPointer(bitPattern: UInt(layout.bytesBaseAddress)) {
            layout.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.copyMemory(from: base, byteCount: raw.count)
            }
        }

        // The guest's heap starts above the image; `brk` grows it and is bounded by the arena.
        let heapStart = geometry.roundUpToHostPage(highest)
        let heapLimit = heapStart + 32 * 1024 * 1024

        // --- 6. protections
        let protectionPlan = space.hostPageProtectionPlan()
        for change in protectionPlan {
            let result = up_protect(
                change.hostRange.lowerBound, Int(change.hostRange.count),
                change.protection.hostProtBits)
            guard result == 0 else {
                throw RunError.protectionFailed(
                    address: change.hostRange.lowerBound, length: UInt64(change.hostRange.count))
            }
        }
        emit(
            "addr_space_pages=\(protectionPlan.count) merged_pages=\(protectionPlan.filter(\.widensBeyondRequest).count)"
        )
        emit("patched_syscall_sites=\(plan.patchedCount)")
        if options.verbose {
            emit("address_space_report:\n\(space.report())")
            emit(
                "initial_stack: sp=0x\(String(layout.stackPointer, radix: 16)) argc=\(layout.argc) bytes=\(layout.bytes.count) auxv_entries=\(layout.auxiliaryVector.count)"
            )
        }

        // --- 7. run
        let host = RealGuestHost(space: space, heapStart: heapStart, heapLimit: heapLimit)
        let dispatcher = SyscallDispatcher.standardPhase2()
        let session = GuestSession(dispatcher: dispatcher, host: host)
        up_set_syscall_handler(GuestSession.syscallTrampoline, Unmanaged.passUnretained(session).toOpaque())

        emit("guest-stdout-begin")
        var status: Int32 = 0
        var reason: Int32 = Int32(UP_EXIT_UNSUPPORTED)
        let runResult = up_guest_run(entryPoint, layout.stackPointer, &status, &reason)
        emit("guest-stdout-end")

        let reasonText: String
        switch runResult {
        case Int32(UP_EXIT_NORMAL): reasonText = "normal"
        case Int32(UP_EXIT_SIGNAL): reasonText = "fault"
        case Int32(UP_EXIT_BREAKPOINT): reasonText = "breakpoint"
        case Int32(UP_EXIT_UNSUPPORTED): reasonText = "unsupported-on-this-host"
        default: reasonText = "host-error(\(runResult))"
        }

        return Result(
            reason: reasonText,
            exitStatus: status,
            syscallCount: dispatcher.trace.total,
            patchedSites: plan.patchedCount,
            placement: mapping.mechanism,
            bias: bias,
            relativeRelocations: relativeRelocations,
            faultSignal: up_last_fault_signal(),
            faultAddress: up_last_fault_address(),
            trapPC: up_last_trap_pc(),
            protectionPages: protectionPlan.count,
            mergedProtectionPages: protectionPlan.filter(\.widensBeyondRequest).count,
            // The host owns the live address space: a guest that called `mmap` while running is only
            // visible there, not in this function's copy made before the run.
            addressSpaceReport: host.addressSpace.report(),
            traceSummary: dispatcher.trace.summary(),
            unimplemented: dispatcher.trace.unknownNumbers.sorted())
    }

    /// Maps the image and reports the base it actually landed at.
    ///
    /// There is one mechanism, a hint, and one rule: the kernel's answer must be the address that was
    /// asked for. A guest address *is* a host address here, so a mapping that lands anywhere else means
    /// the guest's own pointers point somewhere unintended. (`MAP_FIXED` would make the address come
    /// true by discarding whatever is already mapped there — the runtime never wants that, and on Apple
    /// silicon it could not reach the reserved low region anyway.)
    ///
    /// A *biased* placement therefore has a fallback: the next candidate bias. A hint that is refused is
    /// not a failure of the plan, it is information about the address space, and the addresses to try
    /// come from `ImagePlacementPlanner` so the alignment rule is applied in one tested place. An
    /// identity placement has exactly one address — the image was linked there and cannot move — so a
    /// refusal ends the run.
    private func mapImage(
        image: ELFImage,
        placement: ImagePlacement,
        geometry: PageGeometry
    ) throws -> (bias: UInt64, lowest: UInt64, highest: UInt64, mechanism: String) {
        let segments = image.loadSegments
        guard let lowestVirtual = segments.map(\.virtualAddress).min(),
            let highestVirtual = segments.map({ $0.virtualAddress + $0.memorySize }).max()
        else {
            throw RunError.cannotReadImage("the image has no PT_LOAD segments")
        }
        let alignment = max(segments.map(\.alignment).max() ?? 1, 1)
        let planner = ImagePlacementPlanner()

        var candidates = placement.bias == 0
            ? [UInt64(0)]
            : planner.biasCandidates(
                lowest: lowestVirtual, atOrAbove: placement.bias, alignment: alignment)
        var attempts: [String] = []
        var index = 0
        while index < candidates.count {
            let bias = candidates[index]
            index += 1
            let lowest = geometry.roundDownToHostPage(lowestVirtual + bias)
            let highest = geometry.roundUpToHostPage(highestVirtual + bias)
            let length = Int(highest - lowest)
            var landed: UInt64 = 0
            guard up_reserve(lowest, length, Int32(UP_RESERVE_HINT), &landed) != nil else {
                throw RunError.cannotMapImage(
                    address: lowest, length: UInt64(length), landedAt: 0,
                    errno: up_last_mapping_errno())
            }
            if landed == lowest {
                return (
                    bias, lowest, highest,
                    bias == 0 ? "identity" : "biased attempt=\(index)")
            }
            _ = up_release(landed, Int(length))
            attempts.append(
                "asked for 0x\(String(lowest, radix: 16)), the host offered 0x\(String(landed, radix: 16))")

            // A refused hint is also a free address the host just handed us: try it next, converted
            // into a bias through the same alignment rule (and only while the list is still short, so a
            // host that keeps suggesting the same neighbourhood cannot loop forever).
            if candidates.count < ImagePlacementPlanner.biasAttemptCount * 2 {
                let suggested = planner.bias(
                    lowest: lowestVirtual, atOrAbove: landed, alignment: alignment)
                if !candidates.contains(suggested) { candidates.append(suggested) }
            }
        }
        throw RunError.cannotMapImageAtAnyBias(attempts: attempts)
    }

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = up_random_bytes(base, count) }
        }
        return Data(bytes)
    }
}
