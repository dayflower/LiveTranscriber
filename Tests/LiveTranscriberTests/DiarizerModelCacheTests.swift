import CoreML
import FluidAudio
import Foundation
import Synchronization
import Testing

@testable import LiveTranscriberCore

/// Suspends `wait()` callers until `open()`; late callers pass straight
/// through. Lets the tests hold a stub loader mid-flight deterministically.
private actor Gate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Poll until `condition` holds; fails the test instead of hanging forever.
private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
  for _ in 0..<1000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("condition never became true")
}

@Suite("SingleEntryLoadCache")
struct SingleEntryLoadCacheTests {
  @Test func secondRequestForSameKeyIsACacheHit() async throws {
    let loads = Counter()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, _ in
      await loads.increment()
      return key * 10
    }
    #expect(try await cache.value(for: 1) == 10)
    #expect(try await cache.value(for: 1) == 10)
    #expect(await loads.value == 1)
  }

  @Test func concurrentRequestsCoalesceIntoOneLoad() async throws {
    let loads = Counter()
    let gate = Gate()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, _ in
      await loads.increment()
      await gate.wait()
      return key * 10
    }

    let first = Task { try await cache.value(for: 1) }
    try await waitUntil { await loads.value == 1 }
    let second = Task { try await cache.value(for: 1) }
    await gate.open()

    #expect(try await first.value == 10)
    #expect(try await second.value == 10)
    #expect(await loads.value == 1)
  }

  @Test func newKeyEvictsThePreviousEntry() async throws {
    let loads = Counter()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, _ in
      await loads.increment()
      return key * 10
    }
    _ = try await cache.value(for: 1)
    _ = try await cache.value(for: 2)
    // 1 was evicted when 2 loaded, so it loads again.
    _ = try await cache.value(for: 1)
    #expect(await loads.value == 3)
  }

  @Test func failedLoadIsNotCachedAndRetries() async throws {
    struct StubError: Error {}
    let loads = Counter()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, _ in
      await loads.increment()
      if await loads.value == 1 { throw StubError() }
      return key * 10
    }
    await #expect(throws: StubError.self) {
      try await cache.value(for: 1)
    }
    #expect(try await cache.value(for: 1) == 10)
    #expect(await loads.value == 2)
  }

  @Test func invalidateDropsTheCachedValue() async throws {
    let loads = Counter()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, _ in
      await loads.increment()
      return key * 10
    }
    _ = try await cache.value(for: 1)
    await cache.invalidate()
    _ = try await cache.value(for: 1)
    #expect(await loads.value == 2)
  }

  @Test func progressReachesEveryWaiterIncludingLateJoiners() async throws {
    let loads = Counter()
    let gate = Gate()
    let cache = SingleEntryLoadCache<Int, Int, Double> { key, progress in
      progress(0.25)
      await loads.increment()
      await gate.wait()
      return key * 10
    }

    let firstFractions = Mutex<[Double]>([])
    let first = Task {
      try await cache.value(for: 1) { fraction in
        firstFractions.withLock { $0.append(fraction) }
      }
    }
    try await waitUntil { await loads.value == 1 }

    // Joins after the loader already reported; must get the replay.
    let secondFractions = Mutex<[Double]>([])
    let second = Task {
      try await cache.value(for: 1) { fraction in
        secondFractions.withLock { $0.append(fraction) }
      }
    }
    try await waitUntil { secondFractions.withLock { !$0.isEmpty } }
    await gate.open()
    _ = try await first.value
    _ = try await second.value

    #expect(firstFractions.withLock { $0 } == [0.25])
    #expect(secondFractions.withLock { $0 } == [0.25])
  }
}

@Suite("DiarizerModelCache load progress")
struct DiarizerLoadProgressTests {
  @Test func downloadReportsItsOwnFraction() {
    let progress = DiarizerModelCache.loadProgress(
      from: DownloadProgress(
        fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4)))
    // 0.25 overall is halfway through the download half.
    #expect(progress.phase == .downloading(fraction: 0.5))
    #expect(progress.fractionCompleted == 0.25)
  }

  @Test func cachedFilesGoStraightToPreparing() {
    // FluidAudio's cached fast path: download "complete" with no files.
    let progress = DiarizerModelCache.loadProgress(
      from: DownloadProgress(
        fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0)))
    #expect(progress.phase == .preparing)
  }

  @Test func compilingIsIndeterminate() {
    let progress = DiarizerModelCache.loadProgress(
      from: DownloadProgress(fractionCompleted: 0.5, phase: .compiling(modelName: "Sortformer")))
    #expect(progress.phase == .preparing)
  }

  @Test func listingOpensTheDownloadAtZero() {
    let progress = DiarizerModelCache.loadProgress(
      from: DownloadProgress(fractionCompleted: 0, phase: .listing))
    #expect(progress.phase == .downloading(fraction: 0))
  }
}

@Suite("DiarizerModelCache compute resolution")
struct DiarizerComputeResolutionTests {
  @Test func explicitSelectionsMapDirectly() {
    for backend in DiarizerBackend.allCases {
      #expect(DiarizerModelCache.resolvedComputeUnits(.cpuOnly, for: backend) == .cpuOnly)
      #expect(DiarizerModelCache.resolvedComputeUnits(.cpuAndGPU, for: backend) == .cpuAndGPU)
      #expect(
        DiarizerModelCache.resolvedComputeUnits(.cpuAndNeuralEngine, for: backend)
          == .cpuAndNeuralEngine)
      #expect(DiarizerModelCache.resolvedComputeUnits(.all, for: backend) == .all)
    }
  }

  @Test func autoMatchesEachBackendsOwnDefault() {
    #expect(DiarizerModelCache.resolvedComputeUnits(.auto, for: .lsEEND) == .cpuOnly)
    // Sortformer's recommendation is RAM-dependent (.all normally, .cpuOnly
    // on constrained devices), so only pin the candidates.
    let sortformer = DiarizerModelCache.resolvedComputeUnits(.auto, for: .sortformer)
    #expect(sortformer == .all || sortformer == .cpuOnly)
  }
}
