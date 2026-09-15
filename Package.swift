// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "m2mdisplay",
    // Core Audio Process Tap 的公开读取接口从 macOS 14.2 开始可用。
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "M2MShared",
            path: "Sources/M2MShared"
        ),
        .testTarget(
            name: "M2MSharedTests",
            dependencies: ["M2MShared"],
            path: "Tests/M2MSharedTests"
        ),
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "M2MSenderCore",
            dependencies: ["M2MShared", "CGVirtualDisplayShim"],
            path: "Sources/M2MSenderCore"
        ),
        .testTarget(
            name: "M2MSenderCoreTests",
            dependencies: ["M2MSenderCore"],
            path: "Tests/M2MSenderCoreTests"
        ),
        .executableTarget(
            name: "M2MSenderCLI",
            dependencies: ["M2MSenderCore", "M2MShared"],
            path: "Sources/M2MSenderCLI"
        ),
        .target(
            name: "M2MReceiverCore",
            dependencies: ["M2MShared"],
            path: "Sources/M2MReceiverCore"
        ),
        .testTarget(
            name: "M2MReceiverCoreTests",
            dependencies: ["M2MReceiverCore"],
            path: "Tests/M2MReceiverCoreTests"
        ),
        .executableTarget(
            name: "M2MReceiverCLI",
            dependencies: ["M2MReceiverCore", "M2MShared"],
            path: "Sources/M2MReceiverCLI"
        ),
        .executableTarget(
            name: "M2MApp",
            dependencies: ["M2MSenderCore", "M2MReceiverCore", "M2MShared"],
            path: "Sources/M2MApp"
        ),
        .testTarget(
            name: "M2MAppTests",
            dependencies: ["M2MApp"],
            path: "Tests/M2MAppTests"
        ),
    ]
)
