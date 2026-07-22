import Foundation

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
}
