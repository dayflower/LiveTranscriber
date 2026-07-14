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
}
