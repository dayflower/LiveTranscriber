import AppKit

/// Menu-bar (status item) icons, loaded from the bundled asset catalog
/// (`Assets.xcassets`: `TrayIcon` idle, `TrayIconRecording` recording). Both
/// imagesets declare a template rendering intent, so the system recolors them
/// and the two states are told apart by shape (waveform vs a `record.circle`
/// mark).
///
/// The catalog is compiled to `Assets.car` by the Swift Build system (`make`
/// passes `--build-system swiftbuild`). If it is missing — e.g. a plain
/// `swift build` with the native build system, which does not compile
/// catalogs — we fall back to the closest SF Symbols so an icon still shows.
enum TrayIcon {
  private static let pointSize = NSSize(width: 18, height: 18)

  static let idle: NSImage = image(named: "TrayIcon", fallbackSymbol: "waveform")
  static let recording: NSImage = image(named: "TrayIconRecording", fallbackSymbol: "record.circle")

  private static func image(named name: String, fallbackSymbol symbol: String) -> NSImage {
    let image =
      Bundle.module.image(forResource: NSImage.Name(name))
      ?? NSImage(systemSymbolName: symbol, accessibilityDescription: name)
      ?? NSImage(size: pointSize)
    image.isTemplate = true
    image.size = pointSize
    return image
  }
}
