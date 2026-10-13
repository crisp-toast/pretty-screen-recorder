// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PrettyStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pretty", targets: ["pretty"]),
        .executable(name: "PrettyStudio", targets: ["PrettyStudio"]),
        .library(name: "PrettyCore", targets: ["PrettyCore"]),
    ],
    targets: [
        .target(
            name: "PrettyCore",
            path: "Sources/PrettyCore",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "pretty",
            dependencies: ["PrettyCore"],
            path: "Sources/pretty"
        ),
        .executableTarget(
            name: "PrettyStudio",
            dependencies: ["PrettyCore"],
            path: "Sources/PrettyStudio"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
