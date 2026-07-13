// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DetachApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(name: "DetachKit"),
        .executableTarget(
            name: "DetachApp",
            dependencies: [
                "DetachKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .executableTarget(name: "DetachWatchdog"),
        .testTarget(name: "DetachKitTests", dependencies: ["DetachKit"]),
        .testTarget(name: "DetachAppTests", dependencies: ["DetachApp"]),
    ]
)
