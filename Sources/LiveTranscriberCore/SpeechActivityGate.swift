import AVFAudio
import Foundation

/// Derives a speech-presence signal from audio energy: per-buffer linear RMS
/// with hysteresis (separate on/off thresholds) and a hangover so pauses
/// between words don't flicker the state.
///
/// This replaces `SpeechDetector`, whose result stream never yields on
/// current macOS 26 builds and occasionally fails with internal errors
/// ("RecogRejected") that can wedge the analyzer. Being energy-based, the
/// gate cannot tell speech from music — app audio carrying BGM reads as
/// continuous speech.
///
/// A watchdog task drives the silent transition while no buffers arrive:
/// ScreenCaptureKit delivers nothing during system silence, so waiting for
/// the next buffer would freeze the state at "speaking".
///
/// `@unchecked Sendable`: state is lock-protected; buffers arrive from
/// capture/mixer queues, hangover checks from the watchdog task.
final class SpeechActivityGate: @unchecked Sendable {
  private let onThreshold: Float
  private let offThreshold: Float
  private let hangover: TimeInterval
  private let now: @Sendable () -> TimeInterval
  private let onChange: @Sendable (Bool) -> Void

  private let lock = NSLock()
  private var speaking = false
  private var lastActiveAt: TimeInterval = 0
  private var watchdog: Task<Void, Never>?

  /// Thresholds are linear RMS on the post-gain stream: speech typically
  /// measures 0.02...0.3, noise floors stay below 0.01. `now` is injectable
  /// for tests.
  init(
    onThreshold: Float = 0.015,
    offThreshold: Float = 0.0075,
    hangover: TimeInterval = 1.0,
    now: @escaping @Sendable () -> TimeInterval = SpeechActivityGate.uptime,
    onChange: @escaping @Sendable (Bool) -> Void
  ) {
    self.onThreshold = onThreshold
    self.offThreshold = offThreshold
    self.hangover = hangover
    self.now = now
    self.onChange = onChange
  }

  deinit {
    watchdog?.cancel()
  }

  /// Returns a sink that classifies each buffer and forwards it unchanged.
  func tap(
    _ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.classify(buffer)
      sink(buffer)
    }
  }

  private func classify(_ buffer: AVAudioPCMBuffer) {
    guard let (squares, frames) = AudioBufferRMS.sumOfSquares(of: buffer) else { return }
    ingest(rms: Float((squares / Double(frames)).squareRoot()))
  }

  /// Internal for tests; production feeds it via `tap`.
  func ingest(rms: Float) {
    let time = now()
    var transition: Bool?
    lock.lock()
    if speaking {
      if rms >= offThreshold {
        lastActiveAt = time
      } else if time - lastActiveAt >= hangover {
        speaking = false
        transition = false
      }
    } else if rms >= onThreshold {
      speaking = true
      lastActiveAt = time
      transition = true
    }
    lock.unlock()
    report(transition)
  }

  /// Flip to silent once the hangover elapses without active audio; called
  /// by the watchdog so the transition fires even when no buffers arrive.
  /// Internal for tests.
  func checkHangover() {
    let time = now()
    var transition: Bool?
    lock.lock()
    if speaking, time - lastActiveAt >= hangover {
      speaking = false
      transition = false
    }
    lock.unlock()
    report(transition)
  }

  private func report(_ transition: Bool?) {
    guard let transition else { return }
    if transition {
      startWatchdog()
    } else {
      stopWatchdog()
    }
    onChange(transition)
  }

  private func startWatchdog() {
    lock.lock()
    defer { lock.unlock() }
    guard watchdog == nil else { return }
    let interval = hangover / 2
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard let self else { return }
        self.checkHangover()
      }
    }
  }

  private func stopWatchdog() {
    lock.lock()
    let task = watchdog
    watchdog = nil
    lock.unlock()
    task?.cancel()
  }

  static let uptime: @Sendable () -> TimeInterval = {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }
}
