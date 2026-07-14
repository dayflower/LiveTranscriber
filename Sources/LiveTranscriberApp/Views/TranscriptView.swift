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
        let speakerColors = speakerColors
        LazyVStack(alignment: .leading, spacing: model.settings.transcriptEntrySpacing) {
          ForEach(session.segments) { segment in
            SegmentRow(
              segment: segment,
              showsTimestamp: session.timestampsEnabled,
              font: model.settings.transcriptFont,
              captionFont: model.settings.transcriptCaptionFont,
              lineSpacing: model.settings.transcriptLineSpacing,
              speakerColor: segment.speaker.flatMap { speakerColors[$0] },
              rowTintEnabled: model.settings.speakerRowTintEnabled
            )
          }
          ForEach(session.volatiles.filter { !$0.text.isEmpty }) { volatile in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "ellipsis")
                .foregroundStyle(.tertiary)
              if let speaker = volatile.speaker {
                SpeakerBadge(
                  speaker: speaker, font: model.settings.transcriptCaptionFont,
                  color: speakerColors[speaker])
              }
              Text(volatile.text)
                .font(model.settings.transcriptFont)
                .lineSpacing(model.settings.transcriptLineSpacing)
                .foregroundStyle(.secondary)
                .italic()
            }
            .speakerRowTint(
              model.settings.speakerRowTintEnabled
                ? volatile.speaker.flatMap { speakerColors[$0] } : nil)
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

  /// Colors assigned by first appearance in the session, cycling through
  /// `speakerPalette`. Derived on each render so retroactive diarization
  /// relabeling keeps colors consistent with the current labels.
  private var speakerColors: [String: Color] {
    var map: [String: Color] = [:]
    let speakers = session.segments.compactMap(\.speaker) + session.volatiles.compactMap(\.speaker)
    for speaker in speakers where map[speaker] == nil {
      map[speaker] = Self.speakerPalette[map.count % Self.speakerPalette.count]
    }
    return map
  }

  private static let speakerPalette: [Color] = [
    .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown,
  ]

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

private struct SegmentRow: View {
  let segment: TranscriptSegment
  let showsTimestamp: Bool
  let font: Font
  let captionFont: Font
  let lineSpacing: Double
  let speakerColor: Color?
  let rowTintEnabled: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsTimestamp {
        Text(segment.date, format: .dateTime.hour().minute().second())
          .font(captionFont.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let speaker = segment.speaker {
        SpeakerBadge(speaker: speaker, font: captionFont, color: speakerColor)
      }
      Text(segment.text)
        .font(font)
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
    }
    .speakerRowTint(rowTintEnabled ? speakerColor : nil)
  }
}

struct SpeakerBadge: View {
  let speaker: String
  let font: Font
  var color: Color?

  var body: some View {
    if let color {
      Text(speaker)
        .font(font.bold())
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.16), in: Capsule())
    } else {
      Text(speaker)
        .font(font.bold())
        .foregroundStyle(.secondary)
    }
  }
}

extension View {
  /// Full-width row background in the speaker's color; layout (padding) is
  /// applied unconditionally so toggling the tint does not shift text.
  fileprivate func speakerRowTint(_ color: Color?) -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background((color ?? .clear).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }
}
