import AppKit

/// Bundle metadata for display. `swift run` produces a bare executable with no
/// Info.plist, so fall back instead of rendering an empty label.
enum AppInfo {
  static let name: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    ?? "LiveTranscriber"

  static let version: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ?? "dev"

  static var displayNameWithVersion: String { "\(name) \(version)" }

  /// Artwork for the About panel. The packaged app carries the compiled Icon
  /// Composer icon (`make-app.sh` runs `actool`); a bare `swift run` executable
  /// has neither that nor an application icon, so fall back to the catalog copy
  /// of the same artwork.
  static let icon: NSImage? =
    Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
    .flatMap { NSImage(contentsOf: $0) }
    ?? Bundle.module.image(forResource: NSImage.Name("AppIconImage"))
}
