import Foundation
import Testing

@testable import LiveTranscriberCore

@Suite("DiarizationAssembler")
struct DiarizationAssemblerTests {
  private typealias Interval = DiarizationAssembler.Interval

  private func seg(_ number: Int, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedSegment {
    DiarizedSegment(speaker: .diarized(number), audioStart: start, audioEnd: end)
  }

  @Test("Slots are numbered from 1 in order of first appearance")
  func slotNumbering() {
    var assembler = DiarizationAssembler()
    let first = assembler.snapshot(
      finalized: [Interval(slot: 2, start: 0, end: 1)], open: [], frontier: 1, source: nil)
    #expect(first?.finalized == [seg(1, 0, 1)])
    let second = assembler.snapshot(
      finalized: [Interval(slot: 0, start: 1, end: 2), Interval(slot: 2, start: 3, end: 4)],
      open: [], frontier: 4, source: nil)
    #expect(second?.finalized == [seg(1, 0, 1), seg(2, 1, 2), seg(1, 3, 4)])
  }

  @Test("Finalized segments accumulate across snapshots")
  func finalizedAccumulates() {
    var assembler = DiarizationAssembler()
    _ = assembler.snapshot(
      finalized: [Interval(slot: 0, start: 0, end: 2)], open: [], frontier: 2, source: nil)
    let snapshot = assembler.snapshot(
      finalized: [Interval(slot: 0, start: 3, end: 5)], open: [], frontier: 5, source: nil)
    #expect(snapshot?.finalized == [seg(1, 0, 2), seg(1, 3, 5)])
  }

  @Test("Open segments carry the update's tentative state and get numbers")
  func openSegments() {
    var assembler = DiarizationAssembler()
    let snapshot = assembler.snapshot(
      finalized: [Interval(slot: 1, start: 0, end: 2)],
      open: [Interval(slot: 3, start: 2, end: 2.8)],
      frontier: 2.5, source: .appAudio)
    #expect(snapshot?.finalized == [seg(1, 0, 2)])
    #expect(snapshot?.open == [seg(2, 2, 2.8)])
    #expect(snapshot?.source == .appAudio)
    #expect(snapshot?.frontier == 2.5)
  }

  @Test("Updates without closed segments are throttled by frontier advance")
  func frontierThrottle() {
    var assembler = DiarizationAssembler()
    #expect(
      assembler.snapshot(
        finalized: [], open: [Interval(slot: 0, start: 0, end: 1)], frontier: 1, source: nil)
        != nil)
    // Frontier advanced less than the interval — suppressed.
    #expect(
      assembler.snapshot(
        finalized: [], open: [Interval(slot: 0, start: 0, end: 1.4)], frontier: 1.4, source: nil)
        == nil)
    // Enough advance since the last *emitted* snapshot.
    #expect(
      assembler.snapshot(
        finalized: [], open: [Interval(slot: 0, start: 0, end: 1.6)], frontier: 1.6, source: nil)
        != nil)
  }

  @Test("A closed segment bypasses the throttle")
  func finalizedBypassesThrottle() {
    var assembler = DiarizationAssembler()
    _ = assembler.snapshot(finalized: [], open: [], frontier: 1, source: nil)
    let snapshot = assembler.snapshot(
      finalized: [Interval(slot: 0, start: 0, end: 1.1)], open: [], frontier: 1.1, source: nil)
    #expect(snapshot?.finalized == [seg(1, 0, 1.1)])
  }

  @Test("Force emits even without new segments or frontier advance")
  func forceEmits() {
    var assembler = DiarizationAssembler()
    _ = assembler.snapshot(
      finalized: [Interval(slot: 0, start: 0, end: 1)], open: [], frontier: 1, source: nil)
    let final = assembler.snapshot(
      finalized: [], open: [], frontier: 1, source: nil, force: true)
    #expect(final?.finalized == [seg(1, 0, 1)])
    #expect(final?.open == [])
  }
}
