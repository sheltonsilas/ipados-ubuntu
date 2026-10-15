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
/// This is Track B's engine room. The sequence is the whole design in one place:
///
/// 1. parse the image and plan the patch that turns every Linux `svc #0` into a breakpoint;
/// 2. map the image at its own virtual addresses (identity mapping — a guest address *is* a host
///    address, which is what makes guest pointers safe to dereference in the syscall services);
/// 3. write the patched image and the Linux initial stack (argc/argv/envp/auxv) into it;
/// 4. protect each host page according to the plan — read-only text stays read-only, and on a 16 KiB
///    host two guest segments sharing a page get the union of their rights;
/// 5. install the trap handler and branch to the entry point. Every syscall then arrives in Swift.
///
/// Nothing here writes an executable mapping: the text is written while it is writable and made
/// executable afterwards, so there is never a writable-and-executable page. See
/// docs/RESEARCH/jit-and-entitlements-on-ios.md for why that matters on a non-jailbroken device.
final class GuestRunner {
    struct Options {
        var executablePath: String
        var arguments: [String]
        var environment: [String]
        var stackSize: Int = 1 << 20
        var verbose: Bool = false
    }

    enum RunError: Error, CustomStringConvertible {
        case cannotReadImage(String)
        case cannotMapImage(address: UInt64, length: UInt64, landedAt: UInt64, errno: Int32)
        case cannotReplaceReservedLowRegion(address: UInt64, length: UInt64, landedAt: UInt64, errno: Int32)
        case cannotMapStack
        case segmentOutsideImage(name: String)
        case protectionFailed(address: UInt64, length: UInt64)
        case guestCannotRunOnThisHost

        var description: String {
            switch self {
            case let .cannotReadImage(description):
                return "cannot read the guest image: \(description)"
            case let .cannotMapImage(address, length, landedAt, errorNumber):
                return
                    "cannot map the guest image at 0x\(String(address, radix: 16)) (0x\(String(length, radix: 16)) bytes, errno \(errorNumber))\(landedAt == 0 ? "" : "; the kernel offered 0x\(String(landedAt, radix: 16))"). A guest address must be a host address, so the runtime refuses to continue rather than run the image somewhere its own pointers do not point."
            case let .cannotReplaceReservedLowRegion(address, length, landedAt, errorNumber):
                return
                    "the guest image at 0x\(String(address, radix: 16)) (0x\(String(length, radix: 16)) bytes) falls inside the host's reserved low region, and replacing that region failed (errno \(errorNumber)\(landedAt == 0 ? "" : ", landed at 0x\(String(landedAt, radix: 16))")). The runner is normally linked with a 64 KiB __PAGEZERO so this cannot happen; see DECISIONS.md decision 0015."
            case .cannotMapStack:
                return "cannot reserve the guest stack"
            case let .segmentOutsideImage(name):
                return "segment \(name) extends past the end of the image file"
            case let .protectionFailed(address, length):
                return
                    "mprotect failed for 0x\(String(address, radix: 16))+0x\(String(length, radix: 16))"
            case .guestCannotRunOnThisHost:
                return "this host cannot execute AArch64 guest code (see the probe mode for details)"
            }
        }
    }

    struct Result {
        var reason: String
        var exitStatus: Int32
        var syscallCount: Int
        var patchedSites: Int
        var faultSignal: Int32
        var faultAddress: UInt64
        var trapPC: UInt64
        var protectionPages: Int
        var mergedProtectionPages: Int
        var addressSpaceReport: String
        var traceSummary: String
        var unimplemented: [Int32]
    }

    private let options: Options
    private let emit: (String) -> Void

    init(options: Options, emit: @escaping (String) -> Void) {
        self.options = options
        self.emit = emit
    }

    func run() throws -> Result {
        guard up_can_run_guest() != 0 else { throw RunError.guestCannotRunOnThisHost }

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

        // --- 2. map the image at its own virtual addresses
        let loadSegments = image.loadSegments
        guard
            let lowest = loadSegments.map({ geometry.roundDownToHostPage($0.virtualAddress) }).min(),
            let highest = loadSegments.map({
                geometry.roundUpToHostPage($0.virtualAddress + $0.memorySize)
            }).max()
        else {
            throw RunError.cannotReadImage("the image has no PT_LOAD segments")
        }
        let imageLength = highest - lowest
        emit("image_span=0x\(String(lowest, radix: 16))-0x\(String(highest, radix: 16))")
        emit("image_mapping=\(try mapImage(address: lowest, length: imageLength, highest: highest))")
        emit("reserved_low_region_bytes=\(up_reserved_low_region_size())")

        var space = GuestAddressSpace(geometry: geometry)

        // --- 3a. the image contents
        for segment in loadSegments {
            let name = "PT_LOAD[\(segment.index)]"
            let end = Int(segment.fileOffset + segment.fileSize)
            guard end <= plan.patchedImage.count else { throw RunError.segmentOutsideImage(name: name) }
            let destination = UnsafeMutableRawPointer(bitPattern: UInt(segment.virtualAddress))
            guard let destination else { throw RunError.segmentOutsideImage(name: name) }
            if segment.fileSize > 0 {
                plan.patchedImage.withUnsafeBytes { raw in
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
                guestRange: segment.virtualAddress..<(segment.virtualAddress + segment.memorySize),
                protection: GuestProtection(elfFlags: segment.flags))
        }

        // --- 3b. the stack, then the Linux initial stack image inside it
        var stackAddress: UInt64 = 0
        guard up_reserve(0, options.stackSize, Int32(UP_RESERVE_HINT), &stackAddress) != nil else {
            throw RunError.cannotMapStack
        }
        try space.map(
            name: "stack",
            guestRange: stackAddress..<(stackAddress + UInt64(options.stackSize)),
            protection: .readWrite)

        let layout = try InitialStackBuilder(
            geometry: geometry,
            stackTop: stackAddress + UInt64(options.stackSize),
            arguments: options.arguments,
            environment: options.environment,
            image: image,
            loadBias: 0,
            executablePath: options.executablePath,
            randomBytes: randomBytes(count: 16),
            hardwareCapabilities: 0x1f
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

        // --- 4. protections
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
            emit("initial_stack: sp=0x\(String(layout.stackPointer, radix: 16)) argc=\(layout.argc) bytes=\(layout.bytes.count) auxv_entries=\(layout.auxiliaryVector.count)")
        }

        // --- 5. run
        let host = RealGuestHost(space: space, heapStart: heapStart, heapLimit: heapLimit)
        let dispatcher = SyscallDispatcher.standardPhase2()
        let session = GuestSession(dispatcher: dispatcher, host: host)
        up_set_syscall_handler(GuestSession.syscallTrampoline, Unmanaged.passUnretained(session).toOpaque())

        emit("guest-stdout-begin")
        var status: Int32 = 0
        var reason: Int32 = Int32(UP_EXIT_UNSUPPORTED)
        let runResult = up_guest_run(image.header.entryPoint, layout.stackPointer, &status, &reason)
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

    /// Maps the image so that its link-time addresses are valid at run time.
    ///
    /// Two mechanisms, in order, and the one that worked is reported to the caller:
    ///
    /// 1. a plain hint. This is the normal path: the runner is linked with a 64 KiB `__PAGEZERO`, so
    ///    the low 4 GiB — where a Linux executable lives, at 0x400000 — is ordinary mappable memory.
    /// 2. `MAP_FIXED`, but *only* when the whole image lies inside the host's reserved low region. That
    ///    region is reserved by the running binary's own `__PAGEZERO` and never holds live data, which is
    ///    what makes replacing it defensible; anywhere else `MAP_FIXED` would silently discard whatever
    ///    was mapped there, and the runtime will not do that.
    private func mapImage(address: UInt64, length: UInt64, highest: UInt64) throws -> String {
        var landed: UInt64 = 0
        guard up_reserve(address, Int(length), Int32(UP_RESERVE_HINT), &landed) != nil else {
            throw RunError.cannotMapImage(
                address: address, length: length, landedAt: 0, errno: up_last_mapping_errno())
        }
        if landed == address { return "hint" }

        _ = up_release(landed, Int(length))
        let reserved = up_reserved_low_region_size()
        guard reserved > 0, highest <= reserved else {
            throw RunError.cannotMapImage(
                address: address, length: length, landedAt: landed,
                errno: up_last_mapping_errno())
        }

        landed = 0
        guard up_reserve(address, Int(length), Int32(UP_RESERVE_REPLACE), &landed) != nil,
            landed == address
        else {
            throw RunError.cannotReplaceReservedLowRegion(
                address: address, length: length, landedAt: landed,
                errno: up_last_mapping_errno())
        }
        emit(
            "note=the guest image was mapped over the host's reserved low region (0x0-0x\(String(reserved, radix: 16))); the linker's -pagezero_size did not take effect"
        )
        return "replace-reserved-low-region"
    }

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = up_random_bytes(base, count) }
        }
        return Data(bytes)
    }
}
