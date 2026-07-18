import AppKit
import SwiftUI

/// The transcript body as a single read-only `NSTextView` (TextKit 2), so
/// selection and Cmd+C span utterances — SwiftUI `Text` selection cannot
/// cross view boundaries. The coordinator reconciles the session's segments
/// into the text storage incrementally and owns the follow-bottom scrolling.
struct TranscriptTextView: NSViewRepresentable {
  var segments: [TranscriptSegment]
  var volatiles: [VolatileText]
  var style: TranscriptStyle
  var sessionID: UUID
  @Binding var isPinnedToBottom: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    // Assemble the TextKit 2 stack by hand. Never touch `layoutManager` on
    // the text view afterwards: that silently downgrades to TextKit 1 and
    // the row-tint fragment delegate stops firing.
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    // Horizontal insets come from the paragraph styles (so the row tint can
    // span the full container width with the text inset inside it).
    container.lineFragmentPadding = 0
    layoutManager.textContainer = container
    layoutManager.delegate = context.coordinator

    let textView = NSTextView(frame: .zero, textContainer: container)
    textView.isEditable = false
    textView.isSelectable = true
    textView.allowsUndo = false
    textView.usesFontPanel = false
    textView.usesRuler = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = .width
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.documentView = textView

    context.coordinator.contentStorage = contentStorage
    context.coordinator.textView = textView
    context.coordinator.scrollView = scrollView
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.scrollViewDidLiveScroll(_:)),
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onPinChange = { [binding = $isPinnedToBottom] pinned in
      binding.wrappedValue = pinned
    }
    coordinator.apply(
      segments: segments, volatiles: volatiles, style: style, sessionID: sessionID)
    // The jump-to-latest button (or Cmd+Down) re-pins through the binding.
    if isPinnedToBottom, !coordinator.isPinned {
      coordinator.isPinned = true
      coordinator.scrollToBottom(animated: true)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var contentStorage: NSTextContentStorage?
    var textView: NSTextView?
    var scrollView: NSScrollView?
    var onPinChange: ((Bool) -> Void)?
    var isPinned = true

    private var renderedSessionID: UUID?
    private var renderedStyle: TranscriptStyle?
    private var renderedColumns: TranscriptRenderer.TranscriptColumns?
    private var rows: [TranscriptRenderer.RenderedRow] = []
    private var volatileLength = 0
    private var renderedVolatiles: [VolatileText] = []

    /// Mirrors the SwiftUI implementation's tolerance for "at the bottom".
    private static let bottomPinThreshold: CGFloat = 40

    func apply(
      segments: [TranscriptSegment], volatiles: [VolatileText], style: TranscriptStyle,
      sessionID: UUID
    ) {
      guard let textStorage = contentStorage?.textStorage else { return }
      let visibleVolatiles = volatiles.filter { !$0.text.isEmpty }
      let colorIndexes = TranscriptRenderer.speakerColorIndexes(
        segments: segments, volatiles: volatiles)
      let columns = TranscriptRenderer.columns(
        segments: segments, volatiles: volatiles, style: style)

      if sessionID != renderedSessionID || style != renderedStyle || columns != renderedColumns {
        let tail = buildTail(
          segments: segments[...], volatiles: visibleVolatiles,
          colorIndexes: colorIndexes, columns: columns, style: style)
        textStorage.setAttributedString(tail.text)
        rows = tail.rows
        volatileLength = tail.volatileLength
        renderedVolatiles = visibleVolatiles
        let switchedSession = sessionID != renderedSessionID
        renderedSessionID = sessionID
        renderedStyle = style
        renderedColumns = columns
        if switchedSession {
          isPinned = true
          scrollToBottom(animated: false, ensureFullLayout: true)
        } else if isPinned {
          scrollToBottom(animated: false)
        }
        return
      }

      if let index = TranscriptRenderer.firstDivergentIndex(
        rows: rows, segments: segments, colorIndexes: colorIndexes)
      {
        // Rebuild from the first divergent paragraph. During recording this
        // is a pure append (index == rows.count); a retroactive diarization
        // relabel or split rewrites only the affected suffix.
        let offset = rows[..<index].reduce(0) { $0 + $1.length }
        let oldLength = rows[index...].reduce(0) { $0 + $1.length } + volatileLength
        let tail = buildTail(
          segments: segments[index...], volatiles: visibleVolatiles,
          colorIndexes: colorIndexes, columns: columns, style: style)
        textStorage.beginEditing()
        textStorage.replaceCharacters(
          in: NSRange(location: offset, length: oldLength), with: tail.text)
        textStorage.endEditing()
        rows.replaceSubrange(index..., with: tail.rows)
        volatileLength = tail.volatileLength
        renderedVolatiles = visibleVolatiles
        if isPinned { scrollToBottom(animated: false) }
      } else if visibleVolatiles != renderedVolatiles {
        // The hottest path — every recognition tick — touches only the
        // trailing volatile range, so a selection held in finalized text
        // is never disturbed.
        let offset = rows.reduce(0) { $0 + $1.length }
        let replacement = NSMutableAttributedString()
        for volatile in visibleVolatiles {
          replacement.append(
            TranscriptRenderer.volatileParagraph(
              for: volatile, colorIndex: volatile.speaker.flatMap { colorIndexes[$0] },
              columns: columns, style: style))
        }
        textStorage.beginEditing()
        textStorage.replaceCharacters(
          in: NSRange(location: offset, length: volatileLength), with: replacement)
        textStorage.endEditing()
        volatileLength = replacement.length
        renderedVolatiles = visibleVolatiles
        if isPinned { scrollToBottom(animated: false) }
      }
    }

    private func buildTail(
      segments: ArraySlice<TranscriptSegment>, volatiles: [VolatileText],
      colorIndexes: [String: Int], columns: TranscriptRenderer.TranscriptColumns,
      style: TranscriptStyle
    ) -> (rows: [TranscriptRenderer.RenderedRow], volatileLength: Int, text: NSAttributedString) {
      let text = NSMutableAttributedString()
      var rows: [TranscriptRenderer.RenderedRow] = []
      for segment in segments {
        let colorIndex = segment.speaker.flatMap { colorIndexes[$0] }
        let paragraph = TranscriptRenderer.paragraph(
          for: segment, colorIndex: colorIndex, columns: columns, style: style)
        rows.append(
          TranscriptRenderer.RenderedRow(
            id: segment.id,
            fingerprint: TranscriptRenderer.fingerprint(of: segment, colorIndex: colorIndex),
            length: paragraph.length))
        text.append(paragraph)
      }
      var volatileLength = 0
      for volatile in volatiles {
        let paragraph = TranscriptRenderer.volatileParagraph(
          for: volatile, colorIndex: volatile.speaker.flatMap { colorIndexes[$0] },
          columns: columns, style: style)
        volatileLength += paragraph.length
        text.append(paragraph)
      }
      return (rows, volatileLength, text)
    }

    /// Fires only for user-driven scrolling (programmatic scrolls do not post
    /// `didLiveScroll`), so it can set the pin directly from the distance:
    /// the bottom-edge elastic bounce yields a distance ≤ 0 and stays pinned.
    @objc func scrollViewDidLiveScroll(_ notification: Notification) {
      guard let scrollView else { return }
      let distance =
        (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.maxY
      let pinned = distance <= Self.bottomPinThreshold
      if pinned != isPinned {
        isPinned = pinned
        onPinChange?(pinned)
      }
    }

    func scrollToBottom(animated: Bool, ensureFullLayout: Bool = false) {
      guard let textView, let scrollView else { return }
      if ensureFullLayout || animated, let layoutManager = textView.textLayoutManager {
        // TextKit 2 lays out lazily on estimated heights; without a full
        // layout pass a jump to the end of a freshly loaded session lands
        // short of the true bottom.
        layoutManager.ensureLayout(for: layoutManager.documentRange)
      }
      guard animated else {
        textView.scrollToEndOfDocument(nil)
        return
      }
      let clipView = scrollView.contentView
      let target = NSPoint(
        x: clipView.bounds.origin.x,
        y: max(0, textView.frame.height - clipView.bounds.height))
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        clipView.animator().setBoundsOrigin(target)
        scrollView.reflectScrolledClipView(clipView)
      }
    }
  }
}

extension TranscriptTextView.Coordinator: NSTextLayoutManagerDelegate {
  nonisolated func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    TranscriptLayoutFragment(textElement: textElement, range: textElement.elementRange)
  }
}

/// Draws the transcript's row decorations behind its paragraph's text: the
/// full-width speaker row tint (`.transcriptRowTint`) and the speaker-name
/// capsule (`.transcriptSpeakerBadge`) — the TextKit counterparts of the old
/// SwiftUI `speakerRowTint` background and `SpeakerBadge` view.
private final class TranscriptLayoutFragment: NSTextLayoutFragment {
  private var paragraphText: NSAttributedString? {
    guard let paragraph = textElement as? NSTextParagraph,
      paragraph.attributedString.length > 0
    else { return nil }
    return paragraph.attributedString
  }

  private var tintColor: NSColor? {
    paragraphText?.attribute(.transcriptRowTint, at: 0, effectiveRange: nil) as? NSColor
  }

  private var containerWidth: CGFloat {
    textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
  }

  /// Vertical extent of the actual glyphs, measured from the baselines and
  /// the fonts' ascent/descent. Line-fragment frames cannot be used
  /// directly: they absorb `lineSpacing` above lines (which would pad the
  /// row top unevenly) and TextKit appends a zero-length extra line after
  /// the document's trailing newline (which would make the last row one
  /// empty line too tall).
  private var textExtent: (top: CGFloat, bottom: CGFloat)? {
    guard let text = paragraphText else { return nil }
    var top = CGFloat.infinity
    var bottom = -CGFloat.infinity
    for line in textLineFragments where line.characterRange.length > 0 {
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      guard let range = line.characterRange.intersection(NSRange(location: 0, length: text.length))
      else { continue }
      text.enumerateAttribute(.font, in: range) { value, _, _ in
        guard let font = value as? NSFont else { return }
        ascent = max(ascent, font.ascender)
        descent = min(descent, font.descender)
      }
      let baseline = line.typographicBounds.minY + line.glyphOrigin.y
      top = min(top, baseline - ascent)
      bottom = max(bottom, baseline - descent)
    }
    return top < bottom ? (top, bottom) : nil
  }

  /// Fragment-local tint rect spanning the full container width. The
  /// fragment's origin sits at the paragraph's first-line indent, not at the
  /// container's left edge, so the container's x = 0 is at
  /// `-layoutFragmentFrame.minX` in fragment coordinates — drawing from
  /// local x = 0 would hug the glyphs on the left and overshoot the
  /// container on the right. Vertically the rect expands by the text inset
  /// into the paragraph-spacing gap reserved for it.
  private func tintRect(textExtent: (top: CGFloat, bottom: CGFloat)) -> CGRect {
    let inset = TranscriptRenderer.rowTextInsetVertical
    return CGRect(
      x: -layoutFragmentFrame.minX, y: textExtent.top - inset,
      width: containerWidth, height: textExtent.bottom - textExtent.top + 2 * inset)
  }

  // Without widening the rendering surface the decoration fills are clipped
  // to the typographic bounds. Conservative bound: line-fragment geometry is
  // not available yet during layout, so use the whole fragment frame.
  override var renderingSurfaceBounds: CGRect {
    let inset = TranscriptRenderer.rowTextInsetVertical
    let bound = CGRect(
      x: -layoutFragmentFrame.minX, y: -inset,
      width: containerWidth, height: layoutFragmentFrame.height + 2 * inset)
    return super.renderingSurfaceBounds.union(bound)
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    if let tintColor, let textExtent {
      context.saveGState()
      let radius = TranscriptRenderer.rowTintCornerRadius
      context.addPath(
        CGPath(
          roundedRect: tintRect(textExtent: textExtent).offsetBy(dx: point.x, dy: point.y),
          cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.setFillColor(tintColor.withAlphaComponent(TranscriptRenderer.rowTintAlpha).cgColor)
      context.fillPath()
      context.restoreGState()
    }
    drawSpeakerBadges(at: point, in: context)
    super.draw(at: point, in: context)
  }

  private func drawSpeakerBadges(at point: CGPoint, in context: CGContext) {
    guard let text = paragraphText else { return }
    text.enumerateAttribute(
      .transcriptSpeakerBadge, in: NSRange(location: 0, length: text.length)
    ) { value, range, _ in
      guard let color = value as? NSColor,
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      else { return }
      for line in textLineFragments {
        guard let overlap = line.characterRange.intersection(range), overlap.length > 0
        else { continue }
        let bounds = line.typographicBounds
        let start = line.locationForCharacter(at: overlap.location - line.characterRange.location)
        let end = line.locationForCharacter(
          at: overlap.location + overlap.length - line.characterRange.location)
        let baseline = bounds.minY + line.glyphOrigin.y
        let capsule = CGRect(
          x: bounds.minX + start.x - TranscriptRenderer.badgePaddingHorizontal,
          y: baseline - font.ascender - TranscriptRenderer.badgePaddingVertical,
          width: end.x - start.x + 2 * TranscriptRenderer.badgePaddingHorizontal,
          height: font.ascender - font.descender + 2 * TranscriptRenderer.badgePaddingVertical
        )
        context.saveGState()
        context.addPath(
          CGPath(
            roundedRect: capsule.offsetBy(dx: point.x, dy: point.y),
            cornerWidth: capsule.height / 2, cornerHeight: capsule.height / 2, transform: nil))
        context.setFillColor(
          color.withAlphaComponent(TranscriptRenderer.badgeBackgroundAlpha).cgColor)
        context.fillPath()
        context.restoreGState()
      }
    }
  }
}
