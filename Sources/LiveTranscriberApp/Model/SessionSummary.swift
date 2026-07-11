import Foundation

/// Sidebar row for a session stored in the save folder; only the header of
/// the file is parsed. The full transcript loads on selection.
struct SessionSummary: Identifiable, Hashable, Sendable {
  var id: URL { url }

  let url: URL
  let formatID: SessionFormatID
  let name: String
  let startedAt: Date
  let endedAt: Date?
}
