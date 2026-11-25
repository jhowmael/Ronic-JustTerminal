// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RonicJustTerminal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RonicJustTerminal",
            path: "Sources/RonicJustTerminal",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        )
    ]
)
