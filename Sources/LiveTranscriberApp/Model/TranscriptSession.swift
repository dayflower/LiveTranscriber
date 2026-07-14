import Foundation
import Observation

/// One in-progress (volatile) recognition text. With speaker separation two
/// recognizers produce independent volatiles, keyed per engine.
struct VolatileText: Identifiable, Equatable {
  /// Stable per-engine identity: the stream's provisional label (Mic/App;
  /// `nil` with a single unlabeled engine). Keeps the line in place while
  /// the displayed speaker refines.
  let key: String?
  /// Displayed label: the live diarized attribution when one covers the
  /// in-progress audio, else the key.
  var speaker: String?
  var text: String
  var id: String { key ?? "" }
}

/// A transcription session: the one currently recording, or a completed one
/// held in memory / loaded from disk.
@MainActor
@Observable
final class TranscriptSession: Identifiable {
  let id: UUID
  var name: String
  let startedAt: Date
  var endedAt: Date?
  var localeIdentifier: String
  /// Human-readable description of the audio sources (e.g. "MacBook Pro
  /// Microphone + Zoom").
  var sourceDescription: String
  /// User-declared expected length; drives soft auto-stop.
  var estimatedDuration: TimeInterval?
  /// Absolute cap in seconds from start; auto-stops even during speech.
  var hardLimit: TimeInterval?
  var segments: [TranscriptSegment] = []
  /// In-progress recognition texts, updated in place; empty when idle.
  /// One entry per speaker label (a single unlabeled entry without
  /// speaker separation).
  var volatiles: [VolatileText] = []
  /// Whether log entries carry a timestamp prefix (captured from settings at
  /// session start; restored from frontmatter for loaded sessions).
  var timestampsEnabled: Bool = true
  /// Backing file when file saving is enabled; `nil` for memory-only
  /// sessions, which disappear when the app quits.
  var fileURL: URL?

  init(
    id: UUID = UUID(),
    name: String,
    startedAt: Date,
    localeIdentifier: String,
    sourceDescription: String,
    estimatedDuration: TimeInterval? = nil,
    hardLimit: TimeInterval? = nil
  ) {
    self.id = id
    self.name = name
    self.startedAt = startedAt
    self.localeIdentifier = localeIdentifier
    self.sourceDescription = sourceDescription
    self.estimatedDuration = estimatedDuration
    self.hardLimit = hardLimit
  }

  var isRecording: Bool { endedAt == nil }

  /// Value snapshot for file writing.
  func makeSnapshot() -> SessionSnapshot {
    SessionSnapshot(
      name: name,
      startedAt: startedAt,
      endedAt: endedAt,
      localeIdentifier: localeIdentifier,
      sourceDescription: sourceDescription,
      estimatedDuration: estimatedDuration,
      timestampsEnabled: timestampsEnabled,
      segments: segments
    )
  }

  /// Default session name derived from the start time, e.g. "2026-07-11 09:55".
  static func defaultName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMdd HHmm"
    return formatter.string(from: date)
  }
}
