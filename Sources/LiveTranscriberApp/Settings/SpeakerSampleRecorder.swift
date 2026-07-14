import AVFAudio
import Foundation
import LiveTranscriberCore
import Observation

/// Records a speaker-enrollment sample from the system-default microphone,
/// directly at the diarizer's 16 kHz mono Float32 format. The sample only
/// reaches disk when the caller saves it via `SpeakerProfileStore`.
@MainActor
@Observable
final class SpeakerSampleRecorder {
  /// Accumulates converted samples on the capture queue; polled from the
  /// main actor for the level/length display.
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0

    func append(_ buffer: AVAudioPCMBuffer) {
      guard let channel = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      guard count > 0 else { return }
      var sum: Float = 0
      for index in 0..<count {
        sum += channel[index] * channel[index]
      }
      let rms = (sum / Float(count)).squareRoot()
      lock.lock()
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
      level = max(rms, level * 0.8)
      lock.unlock()
    }

    var state: (sampleCount: Int, level: Float) {
      lock.lock()
      defer { lock.unlock() }
      return (samples.count, level)
    }

    func drain() -> [Float] {
      lock.lock()
      defer { lock.unlock() }
      let drained = samples
      samples = []
      level = 0
      return drained
    }
  }

  /// Long enough for a reliable voice signature.
  static let minimumSeconds: TimeInterval = 5
  /// Recording stops itself here; more adds little.
  static let maximumSeconds: TimeInterval = 15

  private(set) var isRecording = false
  /// Smoothed input level (0...1) while recording.
  private(set) var level: Float = 0
  /// Seconds captured so far.
  private(set) var seconds: TimeInterval = 0
  var errorMessage: String?

  private var capture: MicrophoneCapture?
  private var collector = Collector()
  private var pollTask: Task<Void, Never>?

  var hasEnoughAudio: Bool { seconds >= Self.minimumSeconds }

  func start() async {
    guard !isRecording else { return }
    errorMessage = nil
    do {
      try await MicrophoneCapture.requestAccess()
      guard let device = MicrophoneCapture.systemDefaultDevice() else {
        errorMessage = String(localized: "No microphone available.")
        return
      }
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SpeakerProfileStore.sampleRate,
        channels: 1, interleaved: false)!
      let collector = collector
      let capture = MicrophoneCapture(
        outputFormat: format,
        sink: { collector.append($0) },
        onError: { message in
          Task { @MainActor [weak self] in self?.errorMessage = message }
        }
      )
      try capture.start(deviceID: device.id)
      self.capture = capture
      isRecording = true
      seconds = 0
      level = 0
      pollTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(100))
          guard let self, self.isRecording else { return }
          let state = self.collector.state
          self.level = state.level
          self.seconds = TimeInterval(state.sampleCount) / SpeakerProfileStore.sampleRate
          if self.seconds >= Self.maximumSeconds {
            _ = self.stop(keepingSamples: true)
            return
          }
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Stop the capture. The recorded samples stay available via `takeSamples`
  /// until the next `start()`.
  @discardableResult
  func stop(keepingSamples: Bool = true) -> Bool {
    guard isRecording else { return false }
    capture?.stop()
    capture = nil
    pollTask?.cancel()
    pollTask = nil
    isRecording = false
    level = 0
    if !keepingSamples {
      _ = collector.drain()
      seconds = 0
    }
    return true
  }

  /// Hand over the recorded sample and reset for the next take.
  func takeSamples() -> [Float] {
    let samples = collector.drain()
    seconds = 0
    return samples
  }

  func cancel() {
    stop(keepingSamples: false)
  }
}
