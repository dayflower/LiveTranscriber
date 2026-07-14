import Foundation
import Testing

@testable import LiveTranscriberCore

@Suite("DiarizedTurnTracker")
struct DiarizedTurnTrackerTests {
  private typealias Interval = DiarizedTurnTracker.Interval
  private typealias Turn = DiarizedTurnTracker.Turn

  @Test("Slots are numbered from 1 in order of first appearance")
  func slotNumbering() {
    var tracker = DiarizedTurnTracker()
    let first = tracker.turns(finalized: [Interval(slot: 2, start: 0, end: 1)], tentative: [])
    #expect(first.map(\.number) == [1])
    let second = tracker.turns(
      finalized: [
        Interval(slot: 0, start: 1, end: 2),
        Interval(slot: 2, start: 3, end: 4),
      ], tentative: [])
    #expect(second.map(\.number) == [2, 1])
  }

  @Test("Finalized segments are emitted in full")
  func finalizedFullRange() {
    var tracker = DiarizedTurnTracker()
    let turns = tracker.turns(finalized: [Interval(slot: 0, start: 1.5, end: 4)], tentative: [])
    #expect(turns == [Turn(number: 1, start: 1.5, end: 4)])
  }

  @Test("Tentative growth below the delta threshold is suppressed")
  func tentativeSuppressedBelowThreshold() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    #expect(
      tracker.turns(finalized: [], tentative: [Interval(slot: 0, start: 0, end: 1.9)]).isEmpty)
    #expect(
      tracker.turns(finalized: [], tentative: [Interval(slot: 0, start: 0, end: 1.99)]).isEmpty)
  }

  @Test("A growing tentative segment emits deltas from the last emitted end")
  func tentativeDeltas() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    let first = tracker.turns(finalized: [], tentative: [Interval(slot: 1, start: 0, end: 2.5)])
    #expect(first == [Turn(number: 1, start: 0, end: 2.5)])
    // Grown by 1 s only — below the delta threshold.
    #expect(
      tracker.turns(finalized: [], tentative: [Interval(slot: 1, start: 0, end: 3.5)]).isEmpty)
    let second = tracker.turns(finalized: [], tentative: [Interval(slot: 1, start: 0, end: 5)])
    #expect(second == [Turn(number: 1, start: 2.5, end: 5)])
  }

  @Test("A finalized segment advances the tentative frontier of its slot")
  func finalizedAdvancesFrontier() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    _ = tracker.turns(finalized: [Interval(slot: 0, start: 0, end: 6)], tentative: [])
    // The next turn's tentative region only counts past the finalized end.
    #expect(
      tracker.turns(finalized: [], tentative: [Interval(slot: 0, start: 7, end: 8.5)]).isEmpty)
    let turns = tracker.turns(finalized: [], tentative: [Interval(slot: 0, start: 7, end: 9.5)])
    #expect(turns == [Turn(number: 1, start: 7, end: 9.5)])
  }

  @Test("One slot crossing the threshold flushes every slot's pending delta")
  func flushCoversAllSlots() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    let turns = tracker.turns(
      finalized: [],
      tentative: [
        Interval(slot: 0, start: 0, end: 3),
        Interval(slot: 3, start: 2.5, end: 3.2),
      ])
    #expect(
      turns == [
        Turn(number: 1, start: 0, end: 3),
        Turn(number: 2, start: 2.5, end: 3.2),
      ])
  }

  @Test("A finalized segment flushes pending tentative deltas in the same update")
  func finalizedFlushesTentative() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    let turns = tracker.turns(
      finalized: [Interval(slot: 0, start: 0, end: 5)],
      tentative: [Interval(slot: 1, start: 4.5, end: 5.5)])
    #expect(
      turns == [
        Turn(number: 1, start: 0, end: 5),
        Turn(number: 2, start: 4.5, end: 5.5),
      ])
  }

  @Test("A finalized segment and its slot's trailing tentative emit contiguously")
  func finalizedThenTentativeSameSlot() {
    var tracker = DiarizedTurnTracker(minTentativeDelta: 2)
    let turns = tracker.turns(
      finalized: [Interval(slot: 0, start: 0, end: 5)],
      tentative: [Interval(slot: 0, start: 5.5, end: 6.5)])
    #expect(
      turns == [
        Turn(number: 1, start: 0, end: 5),
        Turn(number: 1, start: 5.5, end: 6.5),
      ])
  }
}
