import Foundation

/// Assembles a streaming diarizer's timeline updates into
/// `DiarizationSnapshot`s, mapping fixed speaker slots to stable 1-based
/// numbers in order of first appearance.
///
/// Finalized segments arrive exactly once (when a turn closes) and
/// accumulate into the snapshot's full history; open segments are the
/// update's complete tentative state and replace the previous ones. Updates
/// without a closed segment only produce a snapshot once the frontier has
/// advanced `snapshotInterval` past the last emitted one, which caps the
/// retro-labeling churn from high-frequency models (LS-EEND updates every
/// ~100 ms); `force` bypasses the throttle for the final flush.
struct DiarizationAssembler {
  struct Interval: Equatable {
    var slot: Int
    var start: TimeInterval
    var end: TimeInterval
  }

  static let snapshotInterval: TimeInterval = 0.5

  /// Slots occupied by pre-enrolled speakers, labeled by name; anonymous
  /// slots get 1-based numbers in order of first appearance (enrolled slots
  /// do not consume numbers).
  private let enrolledNames: [Int: String]
  private var numbers: [Int: Int] = [:]
  private var finalized: [DiarizedSegment] = []
  private var lastEmittedFrontier: TimeInterval = -.infinity

  init(enrolledNames: [Int: String] = [:]) {
    self.enrolledNames = enrolledNames
  }

  mutating func snapshot(
    finalized newlyFinalized: [Interval], open: [Interval],
    frontier: TimeInterval, source: AudioSource?, force: Bool = false
  ) -> DiarizationSnapshot? {
    for interval in newlyFinalized {
      finalized.append(segment(interval))
    }
    guard
      force || !newlyFinalized.isEmpty
        || frontier - lastEmittedFrontier >= Self.snapshotInterval
    else { return nil }
    lastEmittedFrontier = frontier
    var openSegments: [DiarizedSegment] = []
    for interval in open {
      openSegments.append(segment(interval))
    }
    return DiarizationSnapshot(
      source: source, frontier: frontier, finalized: finalized, open: openSegments)
  }

  private mutating func segment(_ interval: Interval) -> DiarizedSegment {
    DiarizedSegment(
      speaker: label(for: interval.slot),
      audioStart: interval.start,
      audioEnd: interval.end)
  }

  private mutating func label(for slot: Int) -> SpeakerLabel {
    if let name = enrolledNames[slot] { return .named(name) }
    return .diarized(number(for: slot))
  }

  private mutating func number(for slot: Int) -> Int {
    if let number = numbers[slot] { return number }
    let number = numbers.count + 1
    numbers[slot] = number
    return number
  }
}
