import SwiftUI

/// Sidebar: the live session on top, unsaved (memory-only) sessions, then the
/// history read from the save folder.
/// Session awaiting delete confirmation. Stored sessions move to the Trash
/// (recoverable); memory-only sessions are gone for good.
private enum PendingDeletion {
  case memory(TranscriptSession)
  case file(SessionSummary)
}

struct SessionListView: View {
  @Environment(AppModel.self) private var model

  @State private var pendingDeletion: PendingDeletion?

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
            MemorySessionRow(
              session: session,
              onDelete: model.selection == .memory(session.id)
                ? { pendingDeletion = .memory(session) }
                : nil
            )
            .tag(SessionSelection.memory(session.id))
            .contextMenu {
              Button("Delete…", role: .destructive) {
                pendingDeletion = .memory(session)
              }
            }
          }
        }
      }
      if !model.store.summaries.isEmpty {
        Section("Library") {
          ForEach(model.store.summaries) { summary in
            SummaryRow(
              summary: summary,
              onDelete: model.selection == .file(summary.url)
                ? { pendingDeletion = .file(summary) }
                : nil
            )
            .tag(SessionSelection.file(summary.url))
            .contextMenu {
              Button("Move to Trash…", role: .destructive) {
                pendingDeletion = .file(summary)
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onChange(of: model.selection) {
      model.ensureSelectionLoaded()
    }
    .onDeleteCommand {
      deleteSelection()
    }
    .confirmationDialog(
      "Delete this session?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingDeletion
    ) { pending in
      switch pending {
      case .memory(let session):
        Button("Delete", role: .destructive) {
          model.removeMemorySession(session)
        }
      case .file(let summary):
        Button("Move to Trash", role: .destructive) {
          model.trashFileSession(at: summary.url)
        }
      }
    } message: { pending in
      switch pending {
      case .memory(let session):
        Text("“\(session.name)” is not saved to a file and cannot be recovered.")
      case .file(let summary):
        Text("“\(summary.name)” will be moved to the Trash.")
      }
    }
  }

  private func deleteSelection() {
    switch model.selection {
    case .file(let url):
      if let summary = model.store.summaries.first(where: { $0.url == url }) {
        pendingDeletion = .file(summary)
      }
    case .memory(let id):
      if let session = model.memorySessions.first(where: { $0.id == id }) {
        pendingDeletion = .memory(session)
      }
    default:
      break
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
  let onDelete: (() -> Void)?

  var body: some View {
    RowLayout(name: session.name, startedAt: session.startedAt) {
      if let onDelete {
        DeleteButton(help: "Delete this session", action: onDelete)
      }
      Image(systemName: "internaldrive")
        .foregroundStyle(.tertiary)
        .help("Not saved to a file; disappears when the app quits.")
    }
  }
}

private struct SummaryRow: View {
  let summary: SessionSummary
  let onDelete: (() -> Void)?

  var body: some View {
    RowLayout(name: summary.name, startedAt: summary.startedAt) {
      if let onDelete {
        DeleteButton(help: "Move to Trash", action: onDelete)
      }
    }
  }
}

/// Trash accessory shown on the selected row.
private struct DeleteButton: View {
  let help: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.primary)
    .help(help)
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
