import Foundation

/// Merges per-source speech-activity flags into one aggregate stream: the
/// session counts as speaking while any source is speaking, and only
/// aggregate transitions are reported. Keeps silence-driven consumers
/// (auto-stop) source-agnostic when two engines run in parallel.
///
/// `@unchecked Sendable`: state is lock-protected; updates arrive from both
/// engines' result-consumption tasks.
final class ActivityMerger: @unchecked Sendable {
  private let lock = NSLock()
  private var speaking: [SpeakerLabel: Bool] = [:]
  private var aggregate = false
  private let onChange: @Sendable (Bool) -> Void

  init(onChange: @escaping @Sendable (Bool) -> Void) {
    self.onChange = onChange
  }

  func update(_ label: SpeakerLabel, isSpeaking: Bool) {
    var report: Bool?
    lock.lock()
    speaking[label] = isSpeaking
    let merged = speaking.values.contains(true)
    if merged != aggregate {
      aggregate = merged
      report = merged
    }
    lock.unlock()
    if let report {
      onChange(report)
    }
  }
}

/// Merges per-source audio levels into one meter value: the max of each
/// source's latest report, so the meter reflects whichever stream is active.
///
/// `@unchecked Sendable`: state is lock-protected; updates arrive from the
/// per-source metering taps.
final class LevelMerger: @unchecked Sendable {
  private let lock = NSLock()
  private var levels: [SpeakerLabel: Float] = [:]
  private let onLevel: @Sendable (Float) -> Void

  init(onLevel: @escaping @Sendable (Float) -> Void) {
    self.onLevel = onLevel
  }

  func update(_ label: SpeakerLabel, level: Float) {
    lock.lock()
    levels[label] = level
    let merged = levels.values.max() ?? 0
    lock.unlock()
    onLevel(merged)
  }
}
