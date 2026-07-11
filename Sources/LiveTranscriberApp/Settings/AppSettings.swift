import Foundation
import Observation

/// User preferences, backed by `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
  private static let defaults = UserDefaults.standard

  /// Automatically save sessions to files in `saveFolderPath`. The folder is
  /// also the session history: the sidebar lists its contents.
  var saveEnabled: Bool {
    didSet { Self.defaults.set(saveEnabled, forKey: "saveEnabled") }
  }

  var saveFolderPath: String {
    didSet { Self.defaults.set(saveFolderPath, forKey: "saveFolderPath") }
  }

  var formatID: SessionFormatID {
    didSet { Self.defaults.set(formatID.rawValue, forKey: "sessionFormat") }
  }

  /// Prefix each log entry with a wall-clock timestamp (in the window and in
  /// saved files).
  var timestampsEnabled: Bool {
    didSet { Self.defaults.set(timestampsEnabled, forKey: "timestampsEnabled") }
  }

  /// Force-finalize after this many seconds of detected silence (0 = off).
  var silenceFinalizeSeconds: Double {
    didSet { Self.defaults.set(silenceFinalizeSeconds, forKey: "silenceFinalizeSeconds") }
  }

  /// Force-finalize every N seconds during continuous speech (0 = off).
  var periodicFinalizeSeconds: Double {
    didSet { Self.defaults.set(periodicFinalizeSeconds, forKey: "periodicFinalizeSeconds") }
  }

  /// Once the estimated duration has passed, auto-stop after this much
  /// continuous silence.
  var autoStopSilenceSeconds: Double {
    didSet { Self.defaults.set(autoStopSilenceSeconds, forKey: "autoStopSilenceSeconds") }
  }

  /// Hard limit = estimated duration + this many minutes; recording stops
  /// unconditionally past it.
  var hardLimitExtraMinutes: Int {
    didSet { Self.defaults.set(hardLimitExtraMinutes, forKey: "hardLimitExtraMinutes") }
  }

  init() {
    let d = Self.defaults
    saveEnabled = d.object(forKey: "saveEnabled") as? Bool ?? true
    saveFolderPath =
      d.string(forKey: "saveFolderPath")
      ?? NSHomeDirectory().appending("/Documents/LiveTranscriber")
    formatID = d.string(forKey: "sessionFormat").flatMap(SessionFormatID.init) ?? .markdown
    timestampsEnabled = d.object(forKey: "timestampsEnabled") as? Bool ?? true
    silenceFinalizeSeconds = d.object(forKey: "silenceFinalizeSeconds") as? Double ?? 2
    periodicFinalizeSeconds = d.object(forKey: "periodicFinalizeSeconds") as? Double ?? 30
    autoStopSilenceSeconds = d.object(forKey: "autoStopSilenceSeconds") as? Double ?? 60
    hardLimitExtraMinutes = d.object(forKey: "hardLimitExtraMinutes") as? Int ?? 30
  }

  var saveFolderURL: URL {
    URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
  }
}
