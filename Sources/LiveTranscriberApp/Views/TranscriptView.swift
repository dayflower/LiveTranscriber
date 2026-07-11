import SwiftUI

/// The transcript log: finalized segments plus the in-progress (volatile) text
/// updating in place at the bottom, auto-scrolled while content grows.
/// The window title doubles as the (editable) session name.
struct TranscriptView: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(session.segments) { segment in
            SegmentRow(segment: segment, showsTimestamp: session.timestampsEnabled)
          }
          if !session.volatileText.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "ellipsis")
                .foregroundStyle(.tertiary)
              Text(session.volatileText)
                .foregroundStyle(.secondary)
                .italic()
            }
          }
          Color.clear
            .frame(height: 1)
            .id(bottomAnchorID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .onChange(of: session.segments.count) {
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
      }
      .onChange(of: session.volatileText) {
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
      }
    }
    .navigationTitle($session.name)
    .navigationSubtitle(subtitle)
    .onChange(of: session.name) {
      model.persistRename(of: session)
    }
  }

  private let bottomAnchorID = "transcript-bottom"

  private var subtitle: String {
    var parts = [session.sourceDescription, session.localeIdentifier]
    if session.isRecording {
      parts.append(String(localized: "Recording"))
    } else if session.fileURL == nil {
      parts.append(String(localized: "Not saved"))
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

private struct SegmentRow: View {
  let segment: TranscriptSegment
  let showsTimestamp: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsTimestamp {
        Text(segment.date, format: .dateTime.hour().minute().second())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(segment.text)
        .textSelection(.enabled)
    }
  }
}
