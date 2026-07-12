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
            SegmentRow(
              segment: segment,
              showsTimestamp: session.timestampsEnabled,
              font: model.settings.transcriptFont,
              captionFont: model.settings.transcriptCaptionFont
            )
          }
          ForEach(session.volatiles.filter { !$0.text.isEmpty }) { volatile in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "ellipsis")
                .foregroundStyle(.tertiary)
              if let speaker = volatile.speaker {
                SpeakerBadge(speaker: speaker, font: model.settings.transcriptCaptionFont)
              }
              Text(volatile.text)
                .font(model.settings.transcriptFont)
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
      .onChange(of: session.volatiles) {
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
  let font: Font
  let captionFont: Font

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsTimestamp {
        Text(segment.date, format: .dateTime.hour().minute().second())
          .font(captionFont.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let speaker = segment.speaker {
        SpeakerBadge(speaker: speaker, font: captionFont)
      }
      Text(segment.text)
        .font(font)
        .textSelection(.enabled)
    }
  }
}

struct SpeakerBadge: View {
  let speaker: String
  let font: Font

  var body: some View {
    Text(speaker)
      .font(font.bold())
      .foregroundStyle(.secondary)
  }
}
