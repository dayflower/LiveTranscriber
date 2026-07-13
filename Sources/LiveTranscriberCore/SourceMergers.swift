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
  private var speaking: [AudioSource: Bool] = [:]
  private var aggregate = false
  private let onChange: @Sendable (Bool) -> Void

  init(onChange: @escaping @Sendable (Bool) -> Void) {
    self.onChange = onChange
  }

  func update(_ source: AudioSource, isSpeaking: Bool) {
    var report: Bool?
    lock.lock()
    speaking[source] = isSpeaking
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
