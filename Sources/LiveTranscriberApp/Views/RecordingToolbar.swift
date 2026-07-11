import SwiftUI

/// Toolbar contents reflecting the recording state: record/stop, elapsed time,
/// input level, and preparation progress.
struct RecordingToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      switch model.recording.phase {
      case .idle:
        Button {
          model.showingNewSessionSheet = true
        } label: {
          Label("Record", systemImage: "record.circle")
        }
        .help("Start a new recording session")

      case .preparing:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          if let progress = model.recording.modelDownloadProgress {
            Text("Downloading model… \(Int(progress * 100))%")
              .foregroundStyle(.secondary)
          } else {
            Text("Preparing…")
              .foregroundStyle(.secondary)
          }
        }

      case .recording:
        if let session = model.recording.liveSession {
          Text(session.startedAt, style: .timer)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
          EstimatedDurationMenu(session: session)
          CalendarApplyButton(session: session)
        }
        LevelMeter(level: model.recording.audioLevel)
        Button {
          model.recording.stop()
        } label: {
          Label("Stop", systemImage: "stop.circle.fill")
        }
        .tint(.red)
        .help("Stop recording")

      case .stopping:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Stopping…")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Estimated-duration editor available while recording; the auto-stop monitor
/// picks changes up on its next tick.
private struct EstimatedDurationMenu: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model

  private static let choices = [0, 15, 30, 45, 60, 90, 120]

  var body: some View {
    Menu {
      ForEach(Self.choices, id: \.self) { minutes in
        Button {
          apply(minutes: minutes)
        } label: {
          if isCurrent(minutes: minutes) {
            Label(label(minutes: minutes), systemImage: "checkmark")
          } else {
            Text(label(minutes: minutes))
          }
        }
      }
    } label: {
      Label(currentLabel, systemImage: "timer")
    }
    .help("Estimated session duration (drives automatic stop)")
  }

  private func label(minutes: Int) -> String {
    minutes == 0 ? String(localized: "No estimate") : "\(minutes) min"
  }

  private var currentLabel: String {
    guard let estimated = session.estimatedDuration else { return String(localized: "No estimate") }
    return "\(Int(estimated / 60)) min"
  }

  private func isCurrent(minutes: Int) -> Bool {
    session.estimatedDuration == (minutes == 0 ? nil : TimeInterval(minutes * 60))
  }

  private func apply(minutes: Int) {
    let estimated: TimeInterval? = minutes > 0 ? TimeInterval(minutes * 60) : nil
    session.estimatedDuration = estimated
    session.hardLimit = estimated.map {
      $0 + TimeInterval(model.settings.hardLimitExtraMinutes * 60)
    }
  }
}

/// Apply a calendar event (title → session name, event end → estimated
/// duration) to the live session.
private struct CalendarApplyButton: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model
  @State private var showingSuggestions = false

  var body: some View {
    Button {
      showingSuggestions = true
    } label: {
      Label("Calendar", systemImage: "calendar")
    }
    .help("Apply a calendar event's title and duration to this session")
    .popover(isPresented: $showingSuggestions) {
      CalendarSuggestionList(referenceDate: session.startedAt) { candidate in
        session.name = candidate.title
        let estimated = max(60, candidate.endDate.timeIntervalSince(session.startedAt))
        session.estimatedDuration = estimated
        session.hardLimit = estimated + TimeInterval(model.settings.hardLimitExtraMinutes * 60)
        showingSuggestions = false
      }
    }
  }
}

/// Small input-level indicator. Speech RMS rarely exceeds ~0.3, so the value
/// is scaled up for a useful visual range.
private struct LevelMeter: View {
  let level: Float

  var body: some View {
    Gauge(value: min(1, Double(level) * 3)) {
      EmptyView()
    }
    .gaugeStyle(.accessoryLinearCapacity)
    .tint(.green)
    .frame(width: 60)
    .help("Input level")
  }
}
