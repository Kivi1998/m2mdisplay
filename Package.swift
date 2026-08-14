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
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "M2MSender",
            dependencies: ["M2MShared", "CGVirtualDisplayShim"],
            path: "Sources/M2MSender"
        ),
        .executableTarget(
            name: "M2MReceiver",
            dependencies: ["M2MShared"],
            path: "Sources/M2MReceiver"
        ),
    ]
)
