// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-ticktick",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "osaurus-ticktick", type: .dynamic, targets: ["OsaurusTickTick"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "OsaurusTickTick",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/OsaurusTickTick"
        ),
        .testTarget(
            name: "OsaurusTickTickTests",
            dependencies: [
                "OsaurusTickTick",
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/OsaurusTickTickTests"
        )
    ]
)
