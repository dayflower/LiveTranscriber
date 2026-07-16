import AVFAudio
import Foundation

/// Derives a speech-presence signal from audio energy: per-buffer linear RMS
/// with hysteresis (separate on/off thresholds) and a hangover so pauses
/// between words don't flicker the state.
///
/// The same decision squelches the stream: buffers are replaced with silence
/// while the gate reads "not speaking", so an idle room's noise floor is never
/// offered to the recognizer as something to interpret. Squelching mutes in
/// place rather than dropping buffers — the analyzer sequences buffers
/// contiguously, so a dropped one would shift every later timestamp.
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
  /// The release threshold tracks the trigger threshold at this ratio, so a
  /// user-set noise level only has to name one number.
  static let releaseRatio: Float = 0.5

  private let hangover: TimeInterval
  private let now: @Sendable () -> TimeInterval
  private let onChange: @Sendable (Bool) -> Void

  private let lock = NSLock()
  private var onThreshold: Float
  private var offThreshold: Float
  private var speaking = false
  private var lastActiveAt: TimeInterval = 0
  private var watchdog: Task<Void, Never>?

  /// Thresholds are linear RMS on the post-gain stream: speech typically
  /// measures 0.02...0.3, noise floors stay below 0.01. `now` is injectable
  /// for tests.
  init(
    onThreshold: Float = CaptureConfiguration.defaultNoiseThreshold,
    offThreshold: Float = CaptureConfiguration.defaultNoiseThreshold
      * SpeechActivityGate.releaseRatio,
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

  /// Adjust the trigger level while audio flows; the release level follows at
  /// `releaseRatio`.
  func setThreshold(_ value: Float) {
    lock.lock()
    onThreshold = max(0, value)
    offThreshold = onThreshold * Self.releaseRatio
    lock.unlock()
  }

  /// Returns a sink that classifies each buffer, silences it when the gate is
  /// closed, and forwards it.
  func tap(
    _ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.squelch(buffer)
      sink(buffer)
    }
  }

  /// Returns a sink that classifies and squelches in place without forwarding,
  /// for a stream whose owner reads the buffer back after the sink returns
  /// (the mixer's inlet taps).
  func squelching() -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.squelch(buffer)
    }
  }

  private func squelch(_ buffer: AVAudioPCMBuffer) {
    guard let (squares, frames) = AudioBufferRMS.sumOfSquares(of: buffer) else { return }
    guard !ingest(rms: Float((squares / Double(frames)).squareRoot())) else { return }
    Self.silence(buffer)
  }

  /// Classifies one buffer's level and returns whether the gate is open.
  /// Internal for tests; production feeds it via `tap` / `squelching`.
  @discardableResult
  func ingest(rms: Float) -> Bool {
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
    let isOpen = speaking
    lock.unlock()
    report(transition)
    return isOpen
  }

  /// Zero a buffer in place. Every capture path hands its sink a freshly
  /// converted buffer that nothing upstream reads afterwards, the same
  /// assumption `AudioGain` scales under.
  private static func silence(_ buffer: AVAudioPCMBuffer) {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    // Interleaved buffers expose all channels through pointer 0.
    let pointers = buffer.format.isInterleaved ? 1 : channels
    let samplesPerPointer = buffer.format.isInterleaved ? frames * channels : frames

    if let floatData = buffer.floatChannelData {
      for channel in 0..<pointers {
        floatData[channel].update(repeating: 0, count: samplesPerPointer)
      }
    } else if let intData = buffer.int16ChannelData {
      for channel in 0..<pointers {
        intData[channel].update(repeating: 0, count: samplesPerPointer)
      }
    }
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
