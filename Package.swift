// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "live-transcriber",
  platforms: [
    .macOS(.v26)
  ],
  targets: [
    .target(
      name: "LiveTranscriberCore",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .executableTarget(
      name: "LiveTranscriberApp",
      dependencies: ["LiveTranscriberCore"],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "LiveTranscriberTests",
      dependencies: ["LiveTranscriberApp"],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
  ]
)
