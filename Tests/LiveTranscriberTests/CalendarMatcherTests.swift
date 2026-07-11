import Foundation
import Testing

@testable import LiveTranscriberApp

struct CalendarMatcherTests {
  private func event(_ title: String, start: String, minutes: Double)
    -> CalendarService.EventCandidate
  {
    let startDate = SessionFileText.date(fromISO: start)!
    return CalendarService.EventCandidate(
      id: title,
      title: title,
      startDate: startDate,
      endDate: startDate.addingTimeInterval(minutes * 60)
    )
  }

  private var meetingA: CalendarService.EventCandidate {
    event("Meeting A", start: "2026-07-11T09:00:00+09:00", minutes: 50)
  }
  private var meetingB: CalendarService.EventCandidate {
    event("Meeting B", start: "2026-07-11T10:00:00+09:00", minutes: 30)
  }

  /// The memo's example: a session started at 09:55 belongs to the 10:00
  /// event, not the 09:00 one.
  @Test
  func sessionJustBeforeAnEventMatchesIt() {
    let sessionStart = SessionFileText.date(fromISO: "2026-07-11T09:55:00+09:00")!
    let best = CalendarMatcher.bestMatch([meetingA, meetingB], sessionStart: sessionStart)
    #expect(best?.title == "Meeting B")
  }

  /// The memo's counter-example: a session started at 09:15 belongs to the
  /// 09:00 event.
  @Test
  func sessionShortlyAfterAnEventStartMatchesIt() {
    let sessionStart = SessionFileText.date(fromISO: "2026-07-11T09:15:00+09:00")!
    let best = CalendarMatcher.bestMatch([meetingA, meetingB], sessionStart: sessionStart)
    #expect(best?.title == "Meeting A")
  }

  /// Equidistant events: the upcoming one is the more likely reason the
  /// session was started.
  @Test
  func tiePrefersTheUpcomingEvent() {
    let sessionStart = SessionFileText.date(fromISO: "2026-07-11T09:30:00+09:00")!
    let best = CalendarMatcher.bestMatch([meetingA, meetingB], sessionStart: sessionStart)
    #expect(best?.title == "Meeting B")
  }

  @Test
  func rankedOrdersByDistance() {
    let sessionStart = SessionFileText.date(fromISO: "2026-07-11T09:55:00+09:00")!
    let early = event("Early", start: "2026-07-11T08:00:00+09:00", minutes: 30)
    let ranked = CalendarMatcher.ranked([early, meetingA, meetingB], sessionStart: sessionStart)
    #expect(ranked.map(\.title) == ["Meeting B", "Meeting A", "Early"])
  }

  @Test
  func emptyEventsYieldNoMatch() {
    #expect(CalendarMatcher.bestMatch([], sessionStart: .now) == nil)
  }
}
