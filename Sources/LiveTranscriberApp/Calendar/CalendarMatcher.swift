import Foundation

/// Pure matching heuristic: the event whose start time is nearest to the
/// session start wins. A session started at 09:55 matches a 10:00 event; one
/// started at 09:15 matches the 09:00 event. Ties prefer the upcoming event.
enum CalendarMatcher {
  static func ranked(
    _ events: [CalendarService.EventCandidate],
    sessionStart: Date
  ) -> [CalendarService.EventCandidate] {
    events.sorted { lhs, rhs in
      let lhsDistance = abs(lhs.startDate.timeIntervalSince(sessionStart))
      let rhsDistance = abs(rhs.startDate.timeIntervalSince(sessionStart))
      if lhsDistance != rhsDistance {
        return lhsDistance < rhsDistance
      }
      // Same distance on both sides: the upcoming event is the more
      // likely reason this session was started.
      return lhs.startDate > rhs.startDate
    }
  }

  static func bestMatch(
    _ events: [CalendarService.EventCandidate],
    sessionStart: Date
  ) -> CalendarService.EventCandidate? {
    ranked(events, sessionStart: sessionStart).first
  }
}
