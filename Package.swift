// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BusyBlock",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BusyBlockCore", targets: ["BusyBlockCore"]),
        .executable(name: "BusyBlock", targets: ["BusyBlock"]),
        .executable(name: "busyblock-selftest", targets: ["busyblock-selftest"]),
    ],
    targets: [
        .target(name: "BusyBlockCore"),
        .executableTarget(
            name: "BusyBlock",
            dependencies: ["BusyBlockCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Network")]
        ),
        .executableTarget(name: "busyblock-selftest", dependencies: ["BusyBlockCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
