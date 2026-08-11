// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVRouterKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "KVRouterKit",
            targets: ["KVRouterKit"]
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
            name: "KVRouterKit",
            dependencies: [
                .product(
                    name: "SwiftUIIntrospect",
                    package: "swiftui-introspect"
                )
            ],
            path: "Sources/KVRouterKit"
        ),
        .testTarget(
            name: "KVRouterKitTests",
            dependencies: ["KVRouterKit"],
            path: "Tests/KVRouterKitTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
