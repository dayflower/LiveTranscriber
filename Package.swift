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
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
  ],
  targets: [
    .target(
      name: "LiveTranscriberCore",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .executableTarget(
      name: "LiveTranscriberApp",
      dependencies: [
        "LiveTranscriberCore",
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .testTarget(
      name: "LiveTranscriberTests",
      dependencies: ["LiveTranscriberApp", "LiveTranscriberCore"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
  ]
)
