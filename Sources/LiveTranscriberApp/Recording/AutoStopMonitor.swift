import Foundation

/// Watches the live session once per second and triggers the auto-stop rules:
///
/// 1. Estimated duration elapsed AND silence has continued for the configured
///    time → stop (the "soft" end: a meeting that ran a little long ends when
///    everyone stops talking).
/// 2. Hard limit elapsed → stop unconditionally, even during speech.
///
/// The session's `estimatedDuration` / `hardLimit` are read on every tick, so
/// cancelling the auto-stop while recording takes effect immediately.
@MainActor
final class AutoStopMonitor {
  enum Reason {
    case silenceAfterEstimatedDuration
    case hardLimit
  }

  private var task: Task<Void, Never>?

  func start(
    session: TranscriptSession,
    silence: SilenceTracker,
    autoStopSilenceSeconds: TimeInterval,
    onTrigger: @escaping @MainActor (Reason) -> Void
  ) {
    stop()
    task = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }

        let elapsed = Date().timeIntervalSince(session.startedAt)
        if let hardLimit = session.hardLimit, elapsed >= hardLimit {
          onTrigger(.hardLimit)
          break
        }
        if let estimated = session.estimatedDuration,
          elapsed >= estimated,
          autoStopSilenceSeconds > 0,
          silence.silenceDuration() >= autoStopSilenceSeconds
        {
          onTrigger(.silenceAfterEstimatedDuration)
          break
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}
