import SwiftUI

/// What a geometry change has to tell us apart: `distanceFromBottom` opens up
/// both when the reader scrolls up and when the transcript grows beneath them,
/// but only the former moves `offsetY`.
private struct ScrollSnapshot: Equatable {
  var offsetY: CGFloat
  var distanceFromBottom: CGFloat
}

/// The transcript log: finalized segments plus the in-progress (volatile) text
/// updating in place at the bottom. Follows the growing content only while the
/// view is scrolled to the bottom, so reading back through a recording is not
/// fought by every recognition tick.
/// The window title doubles as the (editable) session name.
struct TranscriptView: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model
  @State private var isPinnedToBottom = true
  @State private var scrollPhase: ScrollPhase = .idle

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
      .onScrollPhaseChange { old, new, context in
        scrollPhase = new
        // Settle: a gesture can coast to the bottom edge and have its last
        // geometry land after the phase already went idle. Only ever pins — a
        // gesture that ended away from the bottom unpinned us while it ran.
        if old.isUserDriven, !new.isUserDriven, isAtBottom(context.geometry) {
          isPinnedToBottom = true
        }
      }
      // The geometry moves for three different reasons — the reader scrolling,
      // the transcript growing, and our own follow scroll — so neither the
      // distance nor the offset alone says what the reader wants. Growth does
      // not touch `offsetY`, and only a hands-on drag can mean "let me out of
      // here": releasing at the bottom edge springs `offsetY` back up, which is
      // a bounce, not a reader leaving.
      .onScrollGeometryChange(for: ScrollSnapshot.self) {
        ScrollSnapshot(offsetY: $0.contentOffset.y, distanceFromBottom: distanceFromBottom($0))
      } action: { old, new in
        if new.distanceFromBottom <= Self.bottomPinThreshold {
          if scrollPhase.isUserDriven { isPinnedToBottom = true }
        } else if scrollPhase.isDragging, new.offsetY < old.offsetY {
          isPinnedToBottom = false
        }
      }
      .onChange(of: session.segments.count) {
        scrollToBottomIfPinned(proxy)
      }
      .onChange(of: session.volatiles) {
        scrollToBottomIfPinned(proxy)
      }
      .onChange(of: session.id) {
        isPinnedToBottom = true
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
      }
      .overlay(alignment: .bottom) {
        jumpToLatestButton(proxy)
      }
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
  private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
    let isVisible = !isPinnedToBottom && session.isRecording
    return Button {
      isPinnedToBottom = true
      withAnimation { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
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

  private let bottomAnchorID = "transcript-bottom"

  /// Tolerance for "at the bottom", absorbing rounding and the safe-area
  /// banners coming and going.
  private static let bottomPinThreshold: CGFloat = 40

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

  private func scrollToBottomIfPinned(_ proxy: ScrollViewProxy) {
    guard isPinnedToBottom else { return }
    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
  }

  /// Includes `contentInsets.bottom` because the error/info banners
  /// (`MainWindow`'s bottom safe-area inset) shrink the visible bottom edge.
  private func distanceFromBottom(_ geometry: ScrollGeometry) -> CGFloat {
    geometry.contentSize.height + geometry.contentInsets.bottom
      - (geometry.contentOffset.y + geometry.containerSize.height)
  }

  private func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
    distanceFromBottom(geometry) <= Self.bottomPinThreshold
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

extension ScrollPhase {
  /// Phases the reader set in motion, as opposed to `.animating` — our own
  /// programmatic scroll. `isScrolling` lumps the two together (it is merely
  /// `!= .idle`), which would let a "Jump to Latest" animation masquerade as a
  /// gesture and unpin us again as soon as it settles.
  fileprivate var isUserDriven: Bool {
    switch self {
    case .tracking, .interacting, .decelerating: true
    case .idle, .animating: false
    @unknown default: false
    }
  }

  /// Hands still on: momentum and the bottom-edge bounce are excluded, so a
  /// spring-back is never mistaken for the reader scrolling away.
  fileprivate var isDragging: Bool {
    switch self {
    case .tracking, .interacting: true
    case .idle, .decelerating, .animating: false
    @unknown default: false
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
