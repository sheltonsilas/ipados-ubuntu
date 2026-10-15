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
        .executableTarget(
            name: "ubuntupad-run",
            dependencies: ["UbuntuPadCore", "UbuntuPadHost"],
            linkerSettings: [
                // macOS arm64 reserves a 4 GiB __PAGEZERO at the bottom of every process, which makes
                // the low 4 GiB unmappable — and a Linux executable is linked at 0x400000, inside it.
                // Shrinking the reserved region to 64 KiB (still enough to catch null dereferences) lets
                // the guest image be mapped at the address its own pointers already use, so Track B can
                // keep its identity mapping instead of relocating guest code. Decision 0015.
                .unsafeFlags(["-Xlinker", "-pagezero_size", "-Xlinker", "0x10000"],
                             .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "UbuntuPadCoreTests",
            dependencies: ["UbuntuPadCore"]
        ),
    ]
)
