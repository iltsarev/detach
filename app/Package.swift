// swift-tools-version: 5.9
import PackageDescription

let watchdogInfoPlist = Context.environment["DETACH_WATCHDOG_INFO_PLIST"]
    ?? "\(Context.packageDirectory)/Resources/DetachWatchdog-Info.plist"

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
        .executableTarget(
            name: "DetachWatchdog",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", watchdogInfoPlist,
                ]),
            ]),
        .testTarget(name: "DetachKitTests", dependencies: ["DetachKit"]),
        .testTarget(name: "DetachAppTests", dependencies: ["DetachApp"]),
    ]
)
