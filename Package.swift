// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HushType",
    platforms: [
        .macOS(.v14),
        .iOS(.v16)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "HushType",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/HushType",
            exclude: ["Resources/Models", "Resources/AppIcon.icns", "Resources/Info.plist", "Resources/HushType.entitlements",
                      "Resources/menubar-icon.png", "Resources/menubar-icon@2x.png",
                      "Resources/menubar-icon-recording.png", "Resources/menubar-icon-recording@2x.png"]
        ),
    ]
)
