import Foundation

/// Transcripts loaded from the save folder, keyed by file URL and bounded to
/// the few most recently used.
///
/// The bound is the point: the save folder *is* the history, so it grows
/// without limit, and a loaded transcript costs roughly one and a half to two
/// times its file size in memory (~105 KB for an hour, ~210 KB for three).
/// Keeping every session the user has ever clicked would leak the whole
/// history into a long-running process. Holding a handful instead keeps
/// flipping between recent sessions free while capping the cost at a couple
/// of megabytes.
///
/// A value type on purpose: it lives as a stored property of `AppModel`, and
/// `@Observable` only notices a mutation it can see there. Moving the storage
/// into a class of its own would silently stop the detail pane from updating
/// when a load finishes.
@MainActor
struct SessionCache {
  /// Eight covers flipping between the sessions of a working session without
  /// noticeable reloads, for ~1.6 MB at the measured worst case.
  static let capacity = 8

  private var sessions: [URL: TranscriptSession] = [:]
  /// Least-recently used first.
  private var order: [URL] = []

  /// Reading does not reorder: this runs inside SwiftUI body evaluation,
  /// where a side effect would be both surprising and impossible to express.
  /// Callers mark real use with `touch(_:)`.
  subscript(url: URL) -> TranscriptSession? { sessions[url] }

  /// Store `session` as the most recently used entry, dropping the oldest
  /// entries past the capacity. `pinned` is never dropped — it is what the
  /// detail pane is showing, and evicting it would blank the window.
  mutating func insert(_ session: TranscriptSession, for url: URL, keeping pinned: URL?) {
    sessions[url] = session
    order.removeAll { $0 == url }
    order.append(url)
    evict(keeping: pinned)
  }

  /// Mark an entry as most recently used, for a hit that skipped `insert`.
  mutating func touch(_ url: URL) {
    guard sessions[url] != nil, order.last != url else { return }
    order.removeAll { $0 == url }
    order.append(url)
  }

  mutating func remove(_ url: URL) {
    sessions[url] = nil
    // Dropping it from the order too is housekeeping rather than correctness
    // — `evict` skips entries that are no longer in `sessions` — but without
    // it the order list accumulates URLs the cache no longer holds.
    order.removeAll { $0 == url }
  }

  /// Re-key an entry whose file was renamed, keeping its position.
  mutating func move(from old: URL, to new: URL) {
    guard old != new, let session = sessions[old] else { return }
    sessions[old] = nil
    sessions[new] = session
    if let index = order.firstIndex(of: old) {
      order[index] = new
    } else {
      order.append(new)
    }
  }

  private mutating func evict(keeping pinned: URL?) {
    var index = 0
    while sessions.count > Self.capacity, index < order.count {
      let candidate = order[index]
      if candidate == pinned {
        index += 1
        continue
      }
      sessions[candidate] = nil
      order.remove(at: index)
    }
  }
}
