import SwiftUI

/// Sidebar: the live session on top, unsaved (memory-only) sessions, then the
/// history read from the save folder.
struct SessionListView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    List(selection: $model.selection) {
      if let live = model.recording.liveSession {
        Section("Recording") {
          LiveSessionRow(session: live)
            .tag(SessionSelection.live(live.id))
        }
      }
      if !model.memorySessions.isEmpty {
        Section("Not Saved") {
          ForEach(model.memorySessions) { session in
            MemorySessionRow(session: session)
              .tag(SessionSelection.memory(session.id))
          }
        }
      }
      if !model.store.summaries.isEmpty {
        Section("Library") {
          ForEach(model.store.summaries) { summary in
            SummaryRow(summary: summary)
              .tag(SessionSelection.file(summary.url))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onChange(of: model.selection) {
      model.ensureSelectionLoaded()
    }
  }
}

private struct LiveSessionRow: View {
  let session: TranscriptSession

  var body: some View {
    RowLayout(name: session.name, startedAt: session.startedAt) {
      Image(systemName: "record.circle.fill")
        .foregroundStyle(.red)
        .symbolEffect(.pulse)
    }
  }
}

private struct MemorySessionRow: View {
  let session: TranscriptSession

  var body: some View {
    RowLayout(name: session.name, startedAt: session.startedAt) {
      Image(systemName: "internaldrive")
        .foregroundStyle(.tertiary)
        .help("Not saved to a file; disappears when the app quits.")
    }
  }
}

private struct SummaryRow: View {
  let summary: SessionSummary

  var body: some View {
    RowLayout(name: summary.name, startedAt: summary.startedAt) {
      EmptyView()
    }
  }
}

private struct RowLayout<Accessory: View>: View {
  let name: String
  let startedAt: Date
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .lineLimit(1)
        Text(startedAt, format: .dateTime.month().day().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      accessory
    }
  }
}
