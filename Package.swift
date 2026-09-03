// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AppMixer", targets: ["AppMixer"])
    ],
    targets: [
        .executableTarget(
            name: "AppMixer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
