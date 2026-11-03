// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveCaptions",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LiveCaptions",
            path: ".",
            exclude: ["Resources", "Package.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
