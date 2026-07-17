// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVRouter",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "KVRouter",
            targets: ["KVRouter"]
        )
    ],
    targets: [
        .target(
            name: "KVRouter",
            path: "Sources/KVRouter"
        ),
        .testTarget(
            name: "KVRouterTests",
            dependencies: ["KVRouter"],
            path: "Tests/KVRouterTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
