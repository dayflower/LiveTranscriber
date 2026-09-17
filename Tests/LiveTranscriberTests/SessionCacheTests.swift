import Foundation
import Testing

@testable import LiveTranscriberApp

/// The cache is what keeps a growing save folder from growing the process
/// with it, so the bound and the pin are the properties that matter.
@Suite("SessionCache")
struct SessionCacheTests {
  @MainActor
  private func makeSession(_ name: String) -> TranscriptSession {
    TranscriptSession(
      name: name,
      startedAt: Date(timeIntervalSince1970: 1_750_000_000),
      localeIdentifier: "ja-JP",
      sourceDescription: "Microphone"
    )
  }

  private func url(_ index: Int) -> URL {
    URL(fileURLWithPath: "/tmp/sessions/session-\(index).md")
  }

  /// Fill the cache to capacity with sessions 0..<capacity, oldest first.
  @MainActor
  private func filledCache() -> SessionCache {
    var cache = SessionCache()
    for index in 0..<SessionCache.capacity {
      cache.insert(makeSession("s\(index)"), for: url(index), keeping: nil)
    }
    return cache
  }

  @MainActor
  @Test func insertingPastCapacityDropsTheOldest() {
    var cache = filledCache()
    cache.insert(makeSession("new"), for: url(99), keeping: nil)

    #expect(cache[url(0)] == nil)
    #expect(cache[url(99)]?.name == "new")
    for index in 1..<SessionCache.capacity {
      #expect(cache[url(index)] != nil)
    }
  }

  @MainActor
  @Test func capacityHoldsAcrossManyInserts() {
    var cache = SessionCache()
    var live = 0
    for index in 0..<(SessionCache.capacity * 5) {
      cache.insert(makeSession("s\(index)"), for: url(index), keeping: nil)
      live = (0..<(SessionCache.capacity * 5)).count { cache[url($0)] != nil }
      #expect(live <= SessionCache.capacity)
    }
    #expect(live == SessionCache.capacity)
  }

  @MainActor
  @Test func touchingAnEntrySavesItFromEviction() {
    var cache = filledCache()
    // Session 0 is the oldest and next to go; using it moves it to the back.
    cache.touch(url(0))
    cache.insert(makeSession("new"), for: url(99), keeping: nil)

    #expect(cache[url(0)] != nil)
    #expect(cache[url(1)] == nil)  // the new oldest went instead
  }

  @MainActor
  @Test func pinnedEntrySurvivesEvenAsTheOldest() {
    var cache = filledCache()
    // The displayed session must never be evicted, however stale its use.
    for index in 0..<(SessionCache.capacity * 3) {
      cache.insert(makeSession("extra\(index)"), for: url(100 + index), keeping: url(0))
    }
    #expect(cache[url(0)]?.name == "s0")
  }

  @MainActor
  @Test func reinsertingAnExistingURLDoesNotGrowTheCache() {
    var cache = filledCache()
    cache.insert(makeSession("replacement"), for: url(0), keeping: nil)

    #expect(cache[url(0)]?.name == "replacement")
    let live = (0..<SessionCache.capacity).count { cache[url($0)] != nil }
    #expect(live == SessionCache.capacity)
  }

  @MainActor
  @Test func moveRekeysTheSameInstance() {
    var cache = SessionCache()
    let session = makeSession("renamed")
    cache.insert(session, for: url(1), keeping: nil)
    cache.move(from: url(1), to: url(2))

    #expect(cache[url(1)] == nil)
    #expect(cache[url(2)] === session)
  }

  @MainActor
  @Test func moveKeepsTheEntrysPlaceInTheOrder() {
    var cache = filledCache()
    // Renaming the oldest entry must not promote it: it is still the oldest.
    cache.move(from: url(0), to: url(50))
    cache.insert(makeSession("new"), for: url(99), keeping: nil)

    #expect(cache[url(50)] == nil)
    #expect(cache[url(1)] != nil)
  }

  @MainActor
  @Test func removingFreesASlotAndTheEntryStaysGone() {
    var cache = filledCache()
    cache.remove(url(0))
    #expect(cache[url(0)] == nil)

    // The freed slot is real: the next insert fits without evicting anyone.
    cache.insert(makeSession("a"), for: url(100), keeping: nil)
    #expect(cache[url(0)] == nil)
    for index in 1..<SessionCache.capacity {
      #expect(cache[url(index)] != nil)
    }
    #expect(cache[url(100)] != nil)
  }
}
