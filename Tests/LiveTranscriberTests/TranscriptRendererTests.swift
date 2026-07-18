import AppKit
import Foundation
import Testing

@testable import LiveTranscriberApp

/// The transcript document builder feeding the selectable text view: paragraph
/// structure and attributes must stay deterministic, and the fingerprint /
/// divergence pair is the contract the incremental updater relies on.
struct TranscriptRendererTests {
  private let style = TranscriptStyle(
    fontName: "", fontSize: 13, lineSpacing: 0, entrySpacing: 10,
    rowTintEnabled: true, showsTimestamps: true
  )

  private func makeSegment(
    id: UUID = UUID(), text: String = "Hello there.", speaker: String? = nil
  ) -> TranscriptSegment {
    TranscriptSegment(
      id: id, text: text,
      date: Date(timeIntervalSinceReferenceDate: 800_000_000),
      audioStart: nil, audioEnd: nil, speaker: speaker
    )
  }

  // MARK: - Speaker color assignment

  @Test func colorsAssignedByFirstAppearanceAcrossSegmentsAndVolatiles() {
    let segments = [
      makeSegment(speaker: "Speaker 2"),
      makeSegment(speaker: "Speaker 1"),
      makeSegment(speaker: "Speaker 2"),
    ]
    let volatiles = [VolatileText(key: "Mic", speaker: "Speaker 3", text: "…")]
    let indexes = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: volatiles)
    #expect(indexes == ["Speaker 2": 0, "Speaker 1": 1, "Speaker 3": 2])
  }

  @Test func colorsCyclePastPaletteEnd() {
    let count = TranscriptRenderer.speakerPalette.count
    let segments = (0...count).map { makeSegment(speaker: "Speaker \($0)") }
    let indexes = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    #expect(indexes["Speaker 0"] == 0)
    #expect(indexes["Speaker \(count)"] == 0)
  }

  // MARK: - Paragraph structure

  private func makeColumns(
    _ segments: [TranscriptSegment], volatiles: [VolatileText] = [],
    style: TranscriptStyle? = nil
  ) -> TranscriptRenderer.TranscriptColumns {
    TranscriptRenderer.columns(segments: segments, volatiles: volatiles, style: style ?? self.style)
  }

  @Test func paragraphLaysOutTimestampSpeakerAndBody() {
    let segment = makeSegment(text: "Hello.", speaker: "Speaker 1")
    let paragraph = TranscriptRenderer.paragraph(
      for: segment, colorIndex: 0, columns: makeColumns([segment]), style: style)
    let expectedTimestamp = segment.date.formatted(.dateTime.hour().minute().second())
    #expect(paragraph.string == "\(expectedTimestamp)\tSpeaker 1\tHello.\n")

    // The badge attribute covers exactly the speaker run (drawn as a capsule
    // by the layout fragment), not the tab gaps around it.
    let speakerRange = (paragraph.string as NSString).range(of: "Speaker 1")
    var effective = NSRange()
    let badge = paragraph.attribute(
      .transcriptSpeakerBadge, at: speakerRange.location, effectiveRange: &effective)
    #expect(badge is NSColor)
    #expect(effective == speakerRange)
  }

  @Test func paragraphOmitsTimestampAndSpeakerWhenAbsent() {
    var plain = style
    plain.showsTimestamps = false
    let segment = makeSegment(text: "Hello.")
    let paragraph = TranscriptRenderer.paragraph(
      for: segment, colorIndex: nil, columns: makeColumns([segment], style: plain), style: plain)
    #expect(paragraph.string == "Hello.\n")
  }

  @Test func rowTintFollowsSettingAndSpeaker() {
    let spoken = makeSegment(speaker: "Speaker 1")
    let columns = makeColumns([spoken])
    let tinted = TranscriptRenderer.paragraph(
      for: spoken, colorIndex: 0, columns: columns, style: style)
    #expect(tinted.attribute(.transcriptRowTint, at: 0, effectiveRange: nil) is NSColor)

    var untinted = style
    untinted.rowTintEnabled = false
    let plain = TranscriptRenderer.paragraph(
      for: spoken, colorIndex: 0, columns: columns, style: untinted)
    #expect(plain.attribute(.transcriptRowTint, at: 0, effectiveRange: nil) == nil)

    let speakerless = TranscriptRenderer.paragraph(
      for: makeSegment(), colorIndex: nil, columns: columns, style: style)
    #expect(speakerless.attribute(.transcriptRowTint, at: 0, effectiveRange: nil) == nil)
  }

  @Test func volatileParagraphUsesLiteralEllipsisAndItalicBody() {
    let volatile = VolatileText(key: "Mic", speaker: "Speaker 1", text: "typing")
    let paragraph = TranscriptRenderer.volatileParagraph(
      for: volatile, colorIndex: 0, columns: makeColumns([], volatiles: [volatile]), style: style)
    #expect(paragraph.string == "…\tSpeaker 1\ttyping\n")
    #expect(!paragraph.string.contains("\u{FFFC}"))
    let bodyLocation = (paragraph.string as NSString).range(of: "typing").location
    let font = paragraph.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    let color = paragraph.attribute(.foregroundColor, at: bodyLocation, effectiveRange: nil)
    #expect(color as? NSColor == .secondaryLabelColor)
  }

  // MARK: - Fingerprint

  @Test func fingerprintTracksTextSpeakerAndColor() {
    let segment = makeSegment(text: "Hello.", speaker: "Speaker 1")
    let base = TranscriptRenderer.fingerprint(of: segment, colorIndex: 0)
    #expect(TranscriptRenderer.fingerprint(of: segment, colorIndex: 0) == base)

    var relabeled = segment
    relabeled.speaker = "Speaker 2"
    #expect(TranscriptRenderer.fingerprint(of: relabeled, colorIndex: 0) != base)
    #expect(TranscriptRenderer.fingerprint(of: segment, colorIndex: 1) != base)
    #expect(
      TranscriptRenderer.fingerprint(
        of: makeSegment(id: segment.id, text: "Bye.", speaker: "Speaker 1"), colorIndex: 0) != base)
  }

  // MARK: - Divergence

  private func makeRows(
    _ segments: [TranscriptSegment], colorIndexes: [String: Int]
  ) -> [TranscriptRenderer.RenderedRow] {
    segments.map { segment in
      TranscriptRenderer.RenderedRow(
        id: segment.id,
        fingerprint: TranscriptRenderer.fingerprint(
          of: segment, colorIndex: segment.speaker.flatMap { colorIndexes[$0] }),
        length: 1
      )
    }
  }

  @Test func divergenceIsNilWhenUnchanged() {
    let segments = [makeSegment(speaker: "Speaker 1"), makeSegment()]
    let colors = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    let rows = makeRows(segments, colorIndexes: colors)
    #expect(
      TranscriptRenderer.firstDivergentIndex(rows: rows, segments: segments, colorIndexes: colors)
        == nil)
  }

  @Test func appendDivergesAtRenderedCount() {
    var segments = [makeSegment(), makeSegment()]
    let colors = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    let rows = makeRows(segments, colorIndexes: colors)
    segments.append(makeSegment(text: "New."))
    #expect(
      TranscriptRenderer.firstDivergentIndex(rows: rows, segments: segments, colorIndexes: colors)
        == 2)
  }

  @Test func retroactiveRelabelDivergesAtChangedParagraph() {
    var segments = [makeSegment(), makeSegment(speaker: "Speaker 1"), makeSegment()]
    var colors = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    let rows = makeRows(segments, colorIndexes: colors)
    segments[1].speaker = "Speaker 2"
    colors = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    #expect(
      TranscriptRenderer.firstDivergentIndex(rows: rows, segments: segments, colorIndexes: colors)
        == 1)
  }

  @Test func splitSegmentDivergesAtNewIdentity() {
    let segments = [makeSegment(), makeSegment(text: "Long turn.")]
    let colors = TranscriptRenderer.speakerColorIndexes(segments: segments, volatiles: [])
    let rows = makeRows(segments, colorIndexes: colors)
    let split = [
      segments[0],
      makeSegment(text: "Long", speaker: "Speaker 1"),
      makeSegment(text: "turn.", speaker: "Speaker 2"),
    ]
    let splitColors = TranscriptRenderer.speakerColorIndexes(segments: split, volatiles: [])
    #expect(
      TranscriptRenderer.firstDivergentIndex(rows: rows, segments: split, colorIndexes: splitColors)
        == 1)
  }
}
