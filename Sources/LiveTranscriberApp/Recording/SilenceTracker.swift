import Foundation
import Observation

/// Tracks when speech was last present, from `speechActivity` events.
@MainActor
@Observable
final class SilenceTracker {
  private(set) var isSpeaking = false
  private(set) var lastSpeechAt = Date()

  /// Call when a session starts so pre-session silence doesn't count.
  func reset() {
    isSpeaking = false
    lastSpeechAt = Date()
  }

  func update(isSpeaking: Bool) {
    self.isSpeaking = isSpeaking
    if isSpeaking {
      lastSpeechAt = Date()
    }
  }

  /// Continuous silence so far; zero while speech is present.
  func silenceDuration(now: Date = Date()) -> TimeInterval {
    isSpeaking ? 0 : now.timeIntervalSince(lastSpeechAt)
  }
}
