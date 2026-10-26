// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundPath",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "SoundPath", targets: ["SoundPath"])
    ],
    targets: [
        .executableTarget(
            name: "SoundPath",
            path: "Sources/SoundPath",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
