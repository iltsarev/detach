// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DetachApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DetachKit"),
        .executableTarget(name: "DetachApp", dependencies: ["DetachKit"]),
        .executableTarget(name: "DetachWatchdog"),
        .testTarget(name: "DetachKitTests", dependencies: ["DetachKit"]),
    ]
)
