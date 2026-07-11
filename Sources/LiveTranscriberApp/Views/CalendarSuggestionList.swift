import SwiftUI

/// Loads calendar events around `referenceDate` and lists them best-match
/// first; choosing one hands the candidate to `onApply` (name + duration are
/// only ever applied by explicit user choice).
struct CalendarSuggestionList: View {
  let referenceDate: Date
  let onApply: (CalendarService.EventCandidate) -> Void

  @State private var candidates: [CalendarService.EventCandidate]?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .frame(maxWidth: 280)
      } else if let candidates {
        if candidates.isEmpty {
          Text("No calendar events around this time.")
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
              Button {
                onApply(candidate)
              } label: {
                CandidateRow(candidate: candidate, isBestMatch: index == 0)
              }
              .buttonStyle(.plain)
            }
          }
        }
      } else {
        ProgressView("Loading events…")
          .controlSize(.small)
      }
    }
    .padding(12)
    .task {
      do {
        candidates = try await CalendarService().candidates(around: referenceDate)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

private struct CandidateRow: View {
  let candidate: CalendarService.EventCandidate
  let isBestMatch: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isBestMatch ? "star.fill" : "calendar")
        .foregroundStyle(isBestMatch ? .yellow : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(candidate.title)
          .lineLimit(1)
        Text(
          "\(candidate.startDate, format: .dateTime.hour().minute()) – \(candidate.endDate, format: .dateTime.hour().minute()) (\(Int(candidate.duration / 60)) min)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
    .padding(.horizontal, 4)
  }
}
