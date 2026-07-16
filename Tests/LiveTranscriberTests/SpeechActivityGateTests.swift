import AVFAudio
import Foundation
import Testing

@testable import LiveTranscriberCore

@Suite("SpeechActivityGate")
struct SpeechActivityGateTests {
  /// Test-controlled clock and transition recorder around a gate with
  /// round-number thresholds (on 0.1, off 0.05, hangover 1 s).
  private final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var transitions: [Bool] = []
    private(set) var gate: SpeechActivityGate!

    init() {
      gate = SpeechActivityGate(
        onThreshold: 0.1, offThreshold: 0.05, hangover: 1,
        now: { [weak self] in self?.now() ?? 0 },
        onChange: { [weak self] in self?.record($0) }
      )
    }

    func now() -> TimeInterval {
      lock.lock()
      defer { lock.unlock() }
      return time
    }

    func advance(to newTime: TimeInterval) {
      lock.lock()
      time = newTime
      lock.unlock()
    }

    func record(_ isSpeaking: Bool) {
      lock.lock()
      transitions.append(isSpeaking)
      lock.unlock()
    }

    var recorded: [Bool] {
      lock.lock()
      defer { lock.unlock() }
      return transitions
    }
  }

  @Test func silenceBelowOnThresholdNeverTriggers() {
    let harness = Harness()
    for step in 0..<10 {
      harness.advance(to: TimeInterval(step) * 0.1)
      harness.gate.ingest(rms: 0.08)
    }
    #expect(harness.recorded.isEmpty)
  }

  @Test func speechTriggersOnceAndSilenceReleasesAfterHangover() {
    let harness = Harness()
    harness.gate.ingest(rms: 0.2)
    harness.advance(to: 0.5)
    harness.gate.ingest(rms: 0.3)
    #expect(harness.recorded == [true])

    // Below the off threshold, but the hangover has not elapsed yet.
    harness.advance(to: 1.0)
    harness.gate.ingest(rms: 0.01)
    #expect(harness.recorded == [true])

    harness.advance(to: 1.6)
    harness.gate.ingest(rms: 0.01)
    #expect(harness.recorded == [true, false])
  }

  @Test func midLevelAudioKeepsSpeechAliveButCannotStartIt() {
    let harness = Harness()
    // Between off and on: not enough to start.
    harness.gate.ingest(rms: 0.07)
    #expect(harness.recorded.isEmpty)

    harness.advance(to: 1)
    harness.gate.ingest(rms: 0.2)
    #expect(harness.recorded == [true])

    // Between off and on: enough to keep going indefinitely.
    for step in 0..<20 {
      harness.advance(to: 1 + TimeInterval(step + 1))
      harness.gate.ingest(rms: 0.07)
    }
    #expect(harness.recorded == [true])
  }

  @Test func hangoverCheckReleasesWithoutBuffers() {
    let harness = Harness()
    harness.gate.ingest(rms: 0.2)
    #expect(harness.recorded == [true])

    // No buffers arrive (ScreenCaptureKit system silence); the watchdog's
    // check must flip the state on its own.
    harness.advance(to: 2)
    harness.gate.checkHangover()
    #expect(harness.recorded == [true, false])
  }

  @Test func retriggersAfterRelease() {
    let harness = Harness()
    harness.gate.ingest(rms: 0.2)
    harness.advance(to: 2)
    harness.gate.checkHangover()
    harness.advance(to: 3)
    harness.gate.ingest(rms: 0.2)
    #expect(harness.recorded == [true, false, true])
  }

  @Test func thresholdChangesWhileFlowing() {
    let harness = Harness()
    // Below the 0.1 trigger the gate stays shut...
    harness.gate.ingest(rms: 0.08)
    #expect(harness.recorded.isEmpty)

    // ...until the trigger drops under it.
    harness.gate.setThreshold(0.05)
    harness.gate.ingest(rms: 0.08)
    #expect(harness.recorded == [true])
  }

  // MARK: - Squelch

  private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }

  private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  /// Feeds one buffer through `tap` and returns what the engine would see.
  private func passed(_ gate: SpeechActivityGate, _ input: [Float]) -> [Float] {
    nonisolated(unsafe) var forwarded: AVAudioPCMBuffer?
    gate.tap { forwarded = $0 }(buffer(input))
    return samples(of: forwarded!)
  }

  @Test func quietBuffersAreSilencedButStillForwarded() {
    let harness = Harness()
    // RMS 0.02, under the 0.1 trigger: the buffer must still reach the
    // analyzer (it sequences buffers contiguously) but carry no signal.
    #expect(passed(harness.gate, [0.02, -0.02, 0.02, -0.02]) == [0, 0, 0, 0])
  }

  @Test func loudBuffersPassThroughUntouched() {
    let harness = Harness()
    #expect(passed(harness.gate, [0.2, -0.2, 0.2, -0.2]) == [0.2, -0.2, 0.2, -0.2])
  }

  @Test func hangoverKeepsQuietBuffersAudible() {
    let harness = Harness()
    #expect(passed(harness.gate, [0.2, -0.2]) == [0.2, -0.2])

    // A pause between words: quiet, but within the hangover, so the tail is
    // not chopped off.
    harness.advance(to: 0.5)
    #expect(passed(harness.gate, [0.01, -0.01]) == [0.01, -0.01])

    harness.advance(to: 2)
    #expect(passed(harness.gate, [0.01, -0.01]) == [0, 0])
  }

  @Test func squelchingSinkMutesInPlace() {
    let harness = Harness()
    // The mixer reads the buffer back after its inlet tap returns, so muting
    // has to land on the buffer itself rather than on a forwarded copy.
    let input = buffer([0.02, -0.02])
    harness.gate.squelching()(input)
    #expect(samples(of: input) == [0, 0])
  }
}
