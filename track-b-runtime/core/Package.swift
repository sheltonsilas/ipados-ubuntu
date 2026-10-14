// swift-tools-version:5.9
// UbuntuPadCore: the platform-independent part of Track B.
// It must build and test on Linux (CI runs `swift test` on ubuntu-latest) and be linked by the
// iOS shell. Keep Apple-only APIs (Mach, Metal, Darwin specifics) out of this target.
import PackageDescription

let package = Package(
    name: "UbuntuPadCore",
    products: [
        .library(name: "UbuntuPadCore", targets: ["UbuntuPadCore"])
    ],
    targets: [
        .target(name: "UbuntuPadCore"),
        .testTarget(
            name: "UbuntuPadCoreTests",
            dependencies: ["UbuntuPadCore"]
        ),
    ]
)
