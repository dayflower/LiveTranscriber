import Foundation
import Speech

/// Manages on-device speech model assets via `AssetInventory`.
///
/// Models live in a system-wide catalog and are downloaded over the network on
/// first use for a locale. The system caps how many locales one app can keep
/// reserved, so an old reservation is released when the cap is hit.
public enum ModelManager {
  public enum ModelError: LocalizedError {
    case localeNotSupported(String)

    public var errorDescription: String? {
      switch self {
      case .localeNotSupported(let id):
        return "Locale \"\(id)\" is not supported by speech transcription."
      }
    }
  }

  /// Locales the transcriber supports at all (installed or downloadable).
  public static func supportedLocales() async -> [Locale] {
    await SpeechTranscriber.supportedLocales
  }

  /// Locales whose model assets are already installed on this machine.
  public static func installedLocales() async -> [Locale] {
    await SpeechTranscriber.installedLocales
  }

  /// Resolve an arbitrary locale identifier to the supported locale the
  /// transcriber would actually use, or `nil` if unsupported.
  public static func resolveSupportedLocale(identifier: String) async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
  }

  private static func matches(_ locale: Locale, in locales: [Locale]) -> Bool {
    let id = locale.identifier(.bcp47)
    return locales.contains { $0.identifier(.bcp47) == id }
  }

  /// Make sure the model assets for `locale` are reserved and installed for
  /// the given modules, downloading them if needed. Download progress is
  /// reported through `onProgress` (0...1).
  static func ensureAssets(
    for locale: Locale,
    modules: [any SpeechModule],
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard matches(locale, in: await SpeechTranscriber.supportedLocales) else {
      throw ModelError.localeNotSupported(locale.identifier(.bcp47))
    }

    // Reserve the locale before analysis; free the oldest slot when the
    // system-wide reservation cap would be exceeded.
    let reserved = await AssetInventory.reservedLocales
    if !matches(locale, in: reserved), reserved.count >= AssetInventory.maximumReservedLocales,
      let oldest = reserved.last
    {
      await AssetInventory.release(reservedLocale: oldest)
    }
    try await AssetInventory.reserve(locale: locale)

    guard !matches(locale, in: await SpeechTranscriber.installedLocales) else { return }

    guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
    else {
      return
    }
    let observation = request.progress.observe(\.fractionCompleted, options: [.new]) {
      progress, _ in
      onProgress(progress.fractionCompleted)
    }
    defer { observation.invalidate() }
    try await request.downloadAndInstall()
    onProgress(1)
  }
}
