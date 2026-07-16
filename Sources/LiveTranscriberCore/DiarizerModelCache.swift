import CoreML
import FluidAudio
import Foundation
import Synchronization

/// A loaded diarization model shared across sessions and capture streams.
///
/// `@unchecked Sendable`: `MLModel` is not `Sendable`, but Apple documents
/// `prediction` as thread-safe, and this wrapper only exposes let-bound
/// references — each stream builds its own `SortformerModels` container
/// (which holds the per-instance inference buffers) around the shared model.
struct SharedDiarizerModel: @unchecked Sendable {
  let mainModel: MLModel
}

/// How far along a diarization-model load is. The two phases need different
/// treatment in the UI: the download reports real byte progress, while the
/// CoreML load reports nothing at all between start and finish — and it is
/// the phase that dominates once the files are on disk (seconds, and only
/// the OS-level ANE program cache keeps it from being seconds every time).
public struct DiarizerModelLoadProgress: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    /// Fetching the model files, on first use only. `fraction` is this
    /// phase's own 0...1, so it can be shown against a "downloading" label.
    case downloading(fraction: Double)
    /// Handing the files to CoreML. Indeterminate: no progress is reported
    /// until it finishes.
    case preparing
  }

  /// Fraction of the whole load, weighted as FluidAudio weights its phases.
  public let fractionCompleted: Double
  public let phase: Phase
}

/// Fans a single loader's progress out to every waiter that joined the load,
/// replaying the last-reported value to late joiners so their progress
/// indicators do not start from nothing.
final class ProgressFanout<Progress: Sendable>: Sendable {
  private struct State {
    var nextID = 0
    var handlers: [Int: @Sendable (Progress) -> Void] = [:]
    var last: Progress?
  }

  private let state = Mutex(State())

  func add(_ handler: @escaping @Sendable (Progress) -> Void) -> Int {
    let replay = state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      state.handlers[id] = handler
      return (id, state.last)
    }
    if let last = replay.1 { handler(last) }
    return replay.0
  }

  func remove(_ id: Int) {
    state.withLock { _ = $0.handlers.removeValue(forKey: id) }
  }

  func report(_ progress: Progress) {
    let handlers = state.withLock { state in
      state.last = progress
      return Array(state.handlers.values)
    }
    for handler in handlers { handler(progress) }
  }
}

/// Holds at most one loaded value and coalesces concurrent requests for the
/// same key into a single load. Requesting a different key drops the previous
/// entry (callers that already hold the old value keep it alive via ARC).
/// A failed load clears its entry so the next request retries.
actor SingleEntryLoadCache<Key: Hashable & Sendable, Value: Sendable, Progress: Sendable> {
  typealias Loader = @Sendable (Key, @escaping @Sendable (Progress) -> Void) async throws -> Value

  private enum EntryState {
    case loading(Task<Value, any Error>, ProgressFanout<Progress>)
    case loaded(Value)
  }

  private let load: Loader
  private var entry: (key: Key, generation: Int, state: EntryState)?
  private var generation = 0

  init(load: @escaping Loader) {
    self.load = load
  }

  func value(
    for key: Key, progress: (@Sendable (Progress) -> Void)? = nil
  ) async throws -> Value {
    if let entry, entry.key == key {
      switch entry.state {
      case .loaded(let value):
        return value
      case .loading(let task, let fanout):
        return try await join(task, fanout: fanout, progress: progress)
      }
    }

    generation += 1
    let currentGeneration = generation
    let fanout = ProgressFanout<Progress>()
    let load = load
    // Unstructured so one waiter's cancellation never aborts a load other
    // waiters (or the cache) still want.
    let task = Task {
      do {
        let value = try await load(key) { fanout.report($0) }
        self.finishLoad(currentGeneration, value: value)
        return value
      } catch {
        self.clearLoad(currentGeneration)
        throw error
      }
    }
    entry = (key, currentGeneration, .loading(task, fanout))
    return try await join(task, fanout: fanout, progress: progress)
  }

  /// Drop the cached value (and forget an in-flight load; it still completes
  /// for its waiters but is not kept).
  func invalidate() {
    entry = nil
  }

  private func join(
    _ task: Task<Value, any Error>, fanout: ProgressFanout<Progress>,
    progress: (@Sendable (Progress) -> Void)?
  ) async throws -> Value {
    guard let progress else { return try await task.value }
    let id = fanout.add(progress)
    defer { fanout.remove(id) }
    return try await task.value
  }

  private func finishLoad(_ loadGeneration: Int, value: Value) {
    guard let entry, entry.generation == loadGeneration else { return }
    self.entry = (entry.key, entry.generation, .loaded(value))
  }

  private func clearLoad(_ loadGeneration: Int) {
    guard let entry, entry.generation == loadGeneration else { return }
    self.entry = nil
  }
}

/// Process-wide cache for the Sortformer diarization model. Loading it is
/// dominated by the CoreML (ANE) program compile, which FluidAudio redoes on
/// every `loadFromHuggingFace` call even when the model files are on disk —
/// so the app loads the `MLModel` once, keyed by compute units, and every
/// stream and session reuses it. LS-EEND is not cached: it loads fast on the
/// CPU, and its `MLModel` is locked inside a wrapper that would serialize
/// inference across streams if shared.
public final class DiarizerModelCache: Sendable {
  public static let shared = DiarizerModelCache()

  /// The one Sortformer variant the app runs; the cached model and the
  /// per-stream containers built around it must agree on it.
  static let sortformerConfig = SortformerConfig.fastV2_1

  /// Share of the overall fraction FluidAudio's `ProgressReporter` gives the
  /// download phase; the CoreML load occupies the rest. Mirrored here to
  /// recover the download's own fraction from the overall one.
  private static let downloadPhaseWeight = 0.5

  private let cache:
    SingleEntryLoadCache<MLComputeUnits, SharedDiarizerModel, DiarizerModelLoadProgress>

  init(
    load:
      @escaping SingleEntryLoadCache<
        MLComputeUnits, SharedDiarizerModel, DiarizerModelLoadProgress
      >.Loader = { computeUnits, progress in
        let models = try await SortformerModels.loadFromHuggingFace(
          config: DiarizerModelCache.sortformerConfig, computeUnits: computeUnits
        ) { progress(DiarizerModelCache.loadProgress(from: $0)) }
        return SharedDiarizerModel(mainModel: models.mainModel)
      }
  ) {
    self.cache = SingleEntryLoadCache(load: load)
  }

  /// Normalizes FluidAudio's progress into the two phases the UI shows.
  static func loadProgress(from progress: DownloadProgress) -> DiarizerModelLoadProgress {
    let phase: DiarizerModelLoadProgress.Phase
    switch progress.phase {
    case .listing:
      phase = .downloading(fraction: 0)
    case .downloading(_, let totalFiles):
      // The cached fast path reports the download complete with no files at
      // all; nothing is being fetched, so that is already the CoreML load.
      phase =
        totalFiles > 0
        ? .downloading(fraction: min(progress.fractionCompleted / downloadPhaseWeight, 1))
        : .preparing
    case .compiling:
      phase = .preparing
    }
    return DiarizerModelLoadProgress(
      fractionCompleted: progress.fractionCompleted, phase: phase)
  }

  /// Load (or reuse) the shared Sortformer model. First use downloads the
  /// model files; `progress` covers both the download and the CoreML load.
  func sortformerModel(
    computeUnits: MLComputeUnits,
    progress: (@Sendable (DiarizerModelLoadProgress) -> Void)? = nil
  ) async throws -> SharedDiarizerModel {
    try await cache.value(for: computeUnits, progress: progress)
  }

  /// Load the configured model in the background so a diarizing session can
  /// start without waiting for the CoreML compile. Failures are swallowed —
  /// the session-start path retries and reports them. A warm cache returns
  /// without reporting progress at all, so callers can show the load only
  /// when there is one.
  public func prewarm(
    backend: DiarizerBackend, compute: DiarizerCompute,
    progress: (@Sendable (DiarizerModelLoadProgress) -> Void)? = nil
  ) async {
    guard backend == .sortformer else { return }
    _ = try? await cache.value(
      for: Self.resolvedComputeUnits(compute, for: backend), progress: progress)
  }

  /// Drop the cached model (e.g. after the backend or compute-units setting
  /// changed) so its memory is freed once running sessions release it.
  public func invalidate() async {
    await cache.invalidate()
  }

  /// Single source of truth for mapping the app-level compute selection to
  /// CoreML units. `.auto` resolves to what each backend would pick itself,
  /// so it shares a cache entry with the equivalent explicit choice.
  static func resolvedComputeUnits(
    _ compute: DiarizerCompute, for backend: DiarizerBackend
  ) -> MLComputeUnits {
    switch compute {
    case .auto:
      switch backend {
      case .sortformer:
        return SortformerModels.recommendedComputeUnits(for: sortformerConfig)
      case .lsEEND:
        return .cpuOnly
      }
    case .cpuOnly: return .cpuOnly
    case .cpuAndGPU: return .cpuAndGPU
    case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
    case .all: return .all
    }
  }
}
