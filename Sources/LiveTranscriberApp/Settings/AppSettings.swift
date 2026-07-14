import Foundation
import Observation
import SwiftUI

/// An application pinned in Settings so it appears at the top of the
/// app-audio picker. The name is stored so it can be displayed even while
/// the application is not running.
struct PriorityApp: Codable, Hashable, Identifiable, Sendable {
  var id: String { bundleID }
  let bundleID: String
  let name: String
}

/// User preferences, backed by `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
  private static let defaults = UserDefaults.standard

  /// The folder sessions are saved to. It is also the session history: the
  /// sidebar lists its contents. Whether a session is saved at all is chosen
  /// per session in the new-session sheet.
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

  /// Font family for the transcript text; empty means the system font.
  var transcriptFontName: String {
    didSet { Self.defaults.set(transcriptFontName, forKey: "transcriptFontName") }
  }

  var transcriptFontSize: Double {
    didSet { Self.defaults.set(transcriptFontSize, forKey: "transcriptFontSize") }
  }

  /// Extra points between wrapped lines within a transcript entry.
  var transcriptLineSpacing: Double {
    didSet { Self.defaults.set(transcriptLineSpacing, forKey: "transcriptLineSpacing") }
  }

  /// Points between transcript entries.
  var transcriptEntrySpacing: Double {
    didSet { Self.defaults.set(transcriptEntrySpacing, forKey: "transcriptEntrySpacing") }
  }

  /// Tint each transcript row with its speaker's color (badges are always
  /// colored; this extends the color to the row background).
  var speakerRowTintEnabled: Bool {
    didSet { Self.defaults.set(speakerRowTintEnabled, forKey: "speakerRowTintEnabled") }
  }

  /// Applications listed before the rest in the new-session sheet's
  /// app-audio picker. Kept sorted by name; add via `addPriorityApp`.
  var priorityApps: [PriorityApp] {
    didSet { Self.defaults.set(try? JSONEncoder().encode(priorityApps), forKey: "priorityApps") }
  }

  func addPriorityApp(_ app: PriorityApp) {
    priorityApps = (priorityApps + [app]).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Linear input gain (1 = unity) applied to each capture source; adjusted
  /// from the toolbar level meters while recording.
  var microphoneGain: Double {
    didSet { Self.defaults.set(microphoneGain, forKey: "microphoneGain") }
  }

  var appAudioGain: Double {
    didSet { Self.defaults.set(appAudioGain, forKey: "appAudioGain") }
  }

  /// Force-finalize after `silenceFinalizeSeconds` of detected silence.
  var silenceFinalizeEnabled: Bool {
    didSet { Self.defaults.set(silenceFinalizeEnabled, forKey: "silenceFinalizeEnabled") }
  }

  var silenceFinalizeSeconds: Double {
    didSet { Self.defaults.set(silenceFinalizeSeconds, forKey: "silenceFinalizeSeconds") }
  }

  /// Force-finalize every `periodicFinalizeSeconds` during continuous speech.
  var periodicFinalizeEnabled: Bool {
    didSet { Self.defaults.set(periodicFinalizeEnabled, forKey: "periodicFinalizeEnabled") }
  }

  var periodicFinalizeSeconds: Double {
    didSet { Self.defaults.set(periodicFinalizeSeconds, forKey: "periodicFinalizeSeconds") }
  }

  /// Diarized speaker turns shorter than this are discarded. Lower values
  /// pick up short interjections but attribute speakers less reliably.
  var diarizerMinTurnSeconds: Double {
    didSet { Self.defaults.set(diarizerMinTurnSeconds, forKey: "diarizerMinTurnSeconds") }
  }

  /// Also keep the display from sleeping while recording (system sleep is
  /// always prevented during a session).
  var keepDisplayAwake: Bool {
    didSet { Self.defaults.set(keepDisplayAwake, forKey: "keepDisplayAwake") }
  }

  /// Once the estimated duration has passed, auto-stop after
  /// `autoStopSilenceSeconds` of continuous silence.
  var autoStopSilenceEnabled: Bool {
    didSet { Self.defaults.set(autoStopSilenceEnabled, forKey: "autoStopSilenceEnabled") }
  }

  var autoStopSilenceSeconds: Double {
    didSet { Self.defaults.set(autoStopSilenceSeconds, forKey: "autoStopSilenceSeconds") }
  }

  /// Hard limit = estimated duration + `hardLimitExtraMinutes`; recording
  /// stops unconditionally past it.
  var hardLimitEnabled: Bool {
    didSet { Self.defaults.set(hardLimitEnabled, forKey: "hardLimitEnabled") }
  }

  var hardLimitExtraMinutes: Int {
    didSet { Self.defaults.set(hardLimitExtraMinutes, forKey: "hardLimitExtraMinutes") }
  }

  init() {
    let d = Self.defaults
    saveFolderPath =
      d.string(forKey: "saveFolderPath")
      ?? NSHomeDirectory().appending("/Documents/LiveTranscriber")
    formatID = d.string(forKey: "sessionFormat").flatMap(SessionFormatID.init) ?? .markdown
    timestampsEnabled = d.object(forKey: "timestampsEnabled") as? Bool ?? true
    transcriptFontName = d.string(forKey: "transcriptFontName") ?? ""
    transcriptFontSize = d.object(forKey: "transcriptFontSize") as? Double ?? 13
    transcriptLineSpacing = d.object(forKey: "transcriptLineSpacing") as? Double ?? 0
    transcriptEntrySpacing = d.object(forKey: "transcriptEntrySpacing") as? Double ?? 10
    speakerRowTintEnabled = d.object(forKey: "speakerRowTintEnabled") as? Bool ?? true
    priorityApps =
      (d.data(forKey: "priorityApps")
      .flatMap { try? JSONDecoder().decode([PriorityApp].self, from: $0) } ?? [])
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    microphoneGain = d.object(forKey: "microphoneGain") as? Double ?? 1
    appAudioGain = d.object(forKey: "appAudioGain") as? Double ?? 1

    // Legacy convention stored 0 seconds for "off"; migrate that to the
    // explicit toggles and keep the seconds at their defaults.
    let storedSilence = d.object(forKey: "silenceFinalizeSeconds") as? Double
    silenceFinalizeEnabled =
      d.object(forKey: "silenceFinalizeEnabled") as? Bool ?? storedSilence.map { $0 > 0 } ?? true
    silenceFinalizeSeconds = storedSilence.flatMap { $0 > 0 ? $0 : nil } ?? 2

    let storedPeriodic = d.object(forKey: "periodicFinalizeSeconds") as? Double
    periodicFinalizeEnabled =
      d.object(forKey: "periodicFinalizeEnabled") as? Bool ?? storedPeriodic.map { $0 > 0 } ?? true
    periodicFinalizeSeconds = storedPeriodic.flatMap { $0 > 0 ? $0 : nil } ?? 30

    diarizerMinTurnSeconds = d.object(forKey: "diarizerMinTurnSeconds") as? Double ?? 1

    keepDisplayAwake = d.object(forKey: "keepDisplayAwake") as? Bool ?? false

    autoStopSilenceEnabled = d.object(forKey: "autoStopSilenceEnabled") as? Bool ?? true
    autoStopSilenceSeconds = d.object(forKey: "autoStopSilenceSeconds") as? Double ?? 60
    hardLimitEnabled = d.object(forKey: "hardLimitEnabled") as? Bool ?? true
    hardLimitExtraMinutes = d.object(forKey: "hardLimitExtraMinutes") as? Int ?? 30
  }

  // The pipeline and the auto-stop monitor treat 0 as "off".
  var effectiveSilenceFinalizeSeconds: Double {
    silenceFinalizeEnabled ? silenceFinalizeSeconds : 0
  }

  var effectivePeriodicFinalizeSeconds: Double {
    periodicFinalizeEnabled ? periodicFinalizeSeconds : 0
  }

  var effectiveAutoStopSilenceSeconds: Double {
    autoStopSilenceEnabled ? autoStopSilenceSeconds : 0
  }

  var transcriptFont: Font {
    transcriptFontName.isEmpty
      ? .system(size: transcriptFontSize)
      : .custom(transcriptFontName, size: transcriptFontSize)
  }

  /// System-font companion for timestamps and speaker badges, scaled with the
  /// transcript font (caption:body ratio at the 13 pt default is 10:13).
  var transcriptCaptionFont: Font {
    .system(size: (transcriptFontSize * 10 / 13).rounded())
  }

  var saveFolderURL: URL {
    URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
  }
}
