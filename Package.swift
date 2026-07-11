// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "live-transcriber",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    // The executable name doubles as the app-menu title under `swift run`.
    .executable(name: "LiveTranscriber", targets: ["LiveTranscriberApp"])
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
