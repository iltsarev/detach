// swift-tools-version: 5.9
import PackageDescription

let watchdogInfoPlist = Context.environment["DETACH_WATCHDOG_INFO_PLIST"]
    ?? "\(Context.packageDirectory)/Resources/DetachWatchdog-Info.plist"
let appBuildMarkerFile = Context.environment["DETACH_APP_BUILD_MARKER_FILE"]
let appLinkerSettings: [LinkerSetting] = appBuildMarkerFile.map { markerFile in
    [.unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT",
        "-Xlinker", "__detach_build",
        "-Xlinker", markerFile,
    ])]
} ?? []

let package = Package(
    name: "DetachApp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "detach-power", targets: ["DetachPower"]),
        .executable(name: "detach-power-helper", targets: ["DetachPowerHelper"]),
        .executable(name: "detach-state", targets: ["DetachState"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(name: "DetachKit"),
        .executableTarget(
            name: "DetachPower",
            dependencies: ["DetachKit"]),
        .executableTarget(
            name: "DetachPowerHelper",
            dependencies: ["DetachKit"]),
        .executableTarget(
            name: "DetachState",
            dependencies: ["DetachKit"]),
        .executableTarget(
            name: "DetachApp",
            dependencies: [
                "DetachKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: appLinkerSettings),
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
