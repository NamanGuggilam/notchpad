// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchPad",
    platforms: [.macOS(.v14)],
    dependencies: [
        // SwiftTerm 1.20.0, vendored: Shaders.metal switched from .process to .copy so it builds without full Xcode.
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "NotchPad",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/NotchPad"
        ),
    ]
)
