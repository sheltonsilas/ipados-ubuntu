// swift-tools-version:5.9
// UbuntuPadCore: the platform-independent part of Track B.
// It must build and test on Linux (CI runs `swift test` on ubuntu-24.04) and be linked by the
// iOS shell. Keep Apple-only APIs (Mach, Metal, Darwin specifics) out of the library target; the
// host/runner targets below are allowed to use them because they only ever run on Apple platforms.
import PackageDescription

let package = Package(
    name: "UbuntuPadCore",
    products: [
        .library(name: "UbuntuPadCore", targets: ["UbuntuPadCore"]),
        // The Phase 2 test bed: loads a static AArch64 Linux ELF and actually executes it on an
        // aarch64 host. It is a separate executable, not an XCTest bundle, because it must be
        // signed with JIT/executable-memory entitlements in CI — which you cannot do to a test
        // bundle that `swift test` runs inside the `xctest` process.
        .executable(name: "ubuntupad-run", targets: ["ubuntupad-run"]),
    ],
    targets: [
        // C shim: memory primitives, the guest entry trampoline and the signal-based trap handler.
        // Tiny on purpose — the policy lives in Swift, the unavoidable machine code lives here.
        .target(name: "UbuntuPadHost"),
        .target(name: "UbuntuPadCore"),
        // NOTE: this target deliberately has no linker settings. Shrinking macOS's 4 GiB __PAGEZERO at
        // link time (`-pagezero_size`) looked like the clean fix for mapping a Linux executable at its
        // own 0x400000, and it links — but the kernel then killed the binary at startup with no output
        // at all (`Killed: 9`, exit 137), twice. The 4 GiB reservation is a kernel rule for arm64, not
        // an empty region, so the runtime does not try to reach into it: it *places* the image at a
        // bias and applies the image's relative relocations instead. See decision 0019
        // (`UbuntuPadCore.ImagePlacement` and `UbuntuPadCore.Relocations`).
        .executableTarget(
            name: "ubuntupad-run",
            dependencies: ["UbuntuPadCore", "UbuntuPadHost"]
        ),
        .testTarget(
            name: "UbuntuPadCoreTests",
            dependencies: ["UbuntuPadCore"]
        ),
    ]
)
