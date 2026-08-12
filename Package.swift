// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVRouterKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        // The router plus its SwiftUI host. What an app target imports.
        .library(
            name: "KVRouterKit",
            targets: ["KVRouterKit"]
        ),
        // Route model and the `KVRouting` command port — no SwiftUI, no UIKit.
        // What a presentation/domain module imports.
        .library(
            name: "KVRouterCore",
            targets: ["KVRouterCore"]
        ),
        // Spies and fakes. Link from test targets only.
        .library(
            name: "KVRouterTesting",
            targets: ["KVRouterTesting"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/siteline/swiftui-introspect",
            .upToNextMajor(from: "26.0.1")
        )
    ],
    targets: [
        .target(
            name: "KVRouterCore",
            path: "Sources/KVRouterCore"
        ),
        .target(
            name: "KVRouterKit",
            dependencies: [
                "KVRouterCore",
                .product(
                    name: "SwiftUIIntrospect",
                    package: "swiftui-introspect"
                )
            ],
            path: "Sources/KVRouterKit"
        ),
        .target(
            name: "KVRouterTesting",
            dependencies: ["KVRouterCore"],
            path: "Sources/KVRouterTesting"
        ),
        .testTarget(
            name: "KVRouterKitTests",
            dependencies: ["KVRouterKit", "KVRouterTesting"],
            path: "Tests/KVRouterKitTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
