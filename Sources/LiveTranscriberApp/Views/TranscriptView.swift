import SwiftUI

/// The transcript log: finalized segments plus the in-progress (volatile) text
/// updating in place at the bottom, rendered by `TranscriptTextView` as one
/// selectable document so selection can span utterances. Follows the growing
/// content only while scrolled to the bottom, so reading back through a
/// recording is not fought by every recognition tick.
/// The window title doubles as the (editable) session name.
struct TranscriptView: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model
  @State private var isPinnedToBottom = true

  var body: some View {
    TranscriptTextView(
      segments: session.segments,
      volatiles: session.volatiles,
      style: TranscriptStyle(
        fontName: model.settings.transcriptFontName,
        fontSize: model.settings.transcriptFontSize,
        lineSpacing: model.settings.transcriptLineSpacing,
        entrySpacing: model.settings.transcriptEntrySpacing,
        rowTintEnabled: model.settings.speakerRowTintEnabled,
        showsTimestamps: session.timestampsEnabled
      ),
      sessionID: session.id,
      isPinnedToBottom: $isPinnedToBottom
    )
    .overlay(alignment: .bottom) {
      jumpToLatestButton
    }
    .onChange(of: session.id) {
      isPinnedToBottom = true
    }
    .navigationTitle($session.name)
    .navigationSubtitle(subtitle)
    .onChange(of: session.name) {
      model.persistRename(of: session)
    }
  }

  /// Resumes following the live transcript. Kept in the hierarchy (hidden by
  /// opacity) even when not shown so its keyboard shortcut stays registered
  /// for completed sessions, where the button itself would just be noise.
  private var jumpToLatestButton: some View {
    let isVisible = !isPinnedToBottom && session.isRecording
    return Button {
      isPinnedToBottom = true
    } label: {
      Label("Jump to Latest", systemImage: "chevron.down")
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .keyboardShortcut(.downArrow, modifiers: .command)
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .animation(.easeInOut(duration: 0.15), value: isVisible)
    .padding()
  }

  private var subtitle: String {
    var parts = [
      session.startedAt.formatted(.dateTime.month().day().hour().minute()),
      session.sourceDescription,
      session.localeIdentifier,
    ]
    if session.isRecording {
      parts.append(String(localized: "Recording"))
    } else if session.fileURL == nil {
      parts.append(String(localized: "Not saved"))
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
