// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "m2mdisplay",
    platforms: [.macOS(.v14)],
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
        .executableTarget(
            name: "M2MSenderCLI",
            dependencies: ["M2MSenderCore", "M2MShared"],
            path: "Sources/M2MSenderCLI"
        ),
        .executableTarget(
            name: "M2MReceiver",
            dependencies: ["M2MShared"],
            path: "Sources/M2MReceiver"
        ),
    ]
)
