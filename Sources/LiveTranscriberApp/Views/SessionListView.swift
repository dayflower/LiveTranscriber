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
        Section {
          LiveSessionRow(session: live)
            .tag(SessionSelection.live(live.id))
        } header: {
          Text("Recording")
            .font(model.settings.sidebarCaptionFont)
        }
      }
      if !model.memorySessions.isEmpty {
        Section {
          ForEach(model.memorySessions) { session in
            MemorySessionRow(
              session: session,
              onSave: { model.saveMemorySession(session) },
              onDelete: model.selection == .memory(session.id)
                ? { pendingDeletion = .memory(session) }
                : nil
            )
            .tag(SessionSelection.memory(session.id))
            .contextMenu {
              Button("Save to Library") {
                model.saveMemorySession(session)
              }
              Button("Export Transcript…") {
                model.exportSession(session)
              }
              Divider()
              Button("Delete…", role: .destructive) {
                pendingDeletion = .memory(session)
              }
            }
          }
        } header: {
          Text("Not Saved")
            .font(model.settings.sidebarCaptionFont)
        }
      }
      ForEach(SessionDay.group(model.store.summaries)) { day in
        Section {
          ForEach(day.summaries) { summary in
            SummaryRow(
              summary: summary,
              onDelete: model.selection == .file(summary.url)
                ? { pendingDeletion = .file(summary) }
                : nil
            )
            .tag(SessionSelection.file(summary.url))
            .contextMenu {
              Button("Export Transcript…") {
                model.exportFileSession(at: summary.url)
              }
              Divider()
              Button("Move to Trash…", role: .destructive) {
                pendingDeletion = .file(summary)
              }
            }
          }
        } header: {
          Text(day.title)
            .font(model.settings.sidebarCaptionFont)
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

/// One day's worth of stored sessions, used to break the library into
/// date-headed sections. Input order (newest first) is preserved.
private struct SessionDay: Identifiable {
  /// Start of the day, in the current calendar.
  let id: Date
  var summaries: [SessionSummary]

  var title: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(id) { return String(localized: "Today") }
    if calendar.isDateInYesterday(id) { return String(localized: "Yesterday") }
    return id.formatted(.dateTime.year().month().day())
  }

  static func group(_ summaries: [SessionSummary]) -> [SessionDay] {
    let calendar = Calendar.current
    var days: [SessionDay] = []
    for summary in summaries {
      let day = calendar.startOfDay(for: summary.startedAt)
      if days.last?.id == day {
        days[days.count - 1].summaries.append(summary)
      } else {
        days.append(SessionDay(id: day, summaries: [summary]))
      }
    }
    return days
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
  let onSave: () -> Void
  let onDelete: (() -> Void)?

  var body: some View {
    RowLayout(name: session.name, startedAt: session.startedAt) {
      if let onDelete {
        DeleteButton(help: "Delete this session", action: onDelete)
      }
      // The memory-only badge doubles as the one-click way out of it.
      Button(action: onSave) {
        Image(systemName: "memorychip")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.tertiary)
      .help("Not saved to a file; disappears when the app quits. Click to save it.")
    }
  }
}

private struct SummaryRow: View {
  let summary: SessionSummary
  let onDelete: (() -> Void)?

  var body: some View {
    // The section header already carries the date.
    RowLayout(name: summary.name, startedAt: summary.startedAt, showsDate: false) {
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
  @Environment(AppModel.self) private var model

  let name: String
  let startedAt: Date
  var showsDate: Bool = true
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        // The sidebar list style overrides an inherited environment font, so
        // the name has to set it here.
        Text(name)
          .font(model.settings.sidebarFont)
          .lineLimit(1)
        Text(
          startedAt,
          format: showsDate
            ? .dateTime.month().day().hour().minute()
            : .dateTime.hour().minute()
        )
        .font(model.settings.sidebarCaptionFont)
        .foregroundStyle(.secondary)
      }
      Spacer()
      accessory
    }
  }
}
