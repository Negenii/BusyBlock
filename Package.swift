// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BusyBlock",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BusyBlockCore", targets: ["BusyBlockCore"]),
        .executable(name: "busyblock-helper", targets: ["BusyBlockHelper"]),
        .executable(name: "busyblock-selftest", targets: ["busyblock-selftest"]),
    ],
    targets: [
        .target(name: "BusyBlockCore"),
        .executableTarget(
            name: "BusyBlockHelper",
            dependencies: ["BusyBlockCore"],
            path: "Sources/BusyBlock",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Network")]
        ),
        .executableTarget(name: "busyblock-selftest", dependencies: ["BusyBlockCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
