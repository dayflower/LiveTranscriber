import EventKit
import Foundation

/// Fetches calendar events around a session start so the user can apply an
/// event's title and duration to the session. Access is requested on first
/// use (triggering the Calendars TCC prompt).
@MainActor
final class CalendarService {
  /// A calendar event candidate, decoupled from EventKit for matching and
  /// testing.
  struct EventCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
  }

  enum CalendarError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
      switch self {
      case .accessDenied:
        return
          "Calendar access is denied. Allow it in System Settings > Privacy & Security > Calendars."
      }
    }
  }

  private let store = EKEventStore()

  /// Non-all-day events starting within ±`window` of `date`, best match
  /// first (see `CalendarMatcher`).
  func candidates(around date: Date, window: TimeInterval = 3600) async throws -> [EventCandidate] {
    try await ensureAccess()

    let predicate = store.predicateForEvents(
      withStart: date.addingTimeInterval(-window),
      end: date.addingTimeInterval(window),
      calendars: nil
    )
    let events = store.events(matching: predicate)
      .filter { !$0.isAllDay }
      .map { event in
        EventCandidate(
          id: event.eventIdentifier ?? UUID().uuidString,
          title: event.title ?? String(localized: "Untitled event"),
          startDate: event.startDate,
          endDate: event.endDate
        )
      }
    return CalendarMatcher.ranked(events, sessionStart: date)
  }

  private func ensureAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      return
    case .notDetermined:
      guard try await store.requestFullAccessToEvents() else {
        throw CalendarError.accessDenied
      }
    default:
      throw CalendarError.accessDenied
    }
  }
}
