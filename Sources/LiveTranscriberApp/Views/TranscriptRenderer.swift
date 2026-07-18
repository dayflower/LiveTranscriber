import AppKit
import Foundation

extension NSAttributedString.Key {
  /// Paragraph-wide marker consumed by the transcript's layout fragment to
  /// draw the full-width speaker row tint. A drawing concern only: it never
  /// styles glyphs and never survives a plain-text copy.
  static let transcriptRowTint = NSAttributedString.Key("transcriptRowTint")
  /// Marks the speaker-name run; the layout fragment draws a capsule behind
  /// it in this color (a background attribute could only draw a rectangle).
  static let transcriptSpeakerBadge = NSAttributedString.Key("transcriptSpeakerBadge")
}

/// Value snapshot of everything that shapes the transcript's appearance,
/// derived from `AppSettings` (plus the session's timestamp preference) on
/// each render. Equality on the raw values is the "restyle needed" signal.
struct TranscriptStyle: Equatable {
  var fontName: String
  var fontSize: Double
  var lineSpacing: Double
  var entrySpacing: Double
  var rowTintEnabled: Bool
  var showsTimestamps: Bool

  var bodyFont: NSFont {
    fontName.isEmpty
      ? .systemFont(ofSize: fontSize)
      : NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
  }

  /// Caption:body ratio mirrors `AppSettings.captionFont(forBodySize:)`.
  private var captionSize: Double { (fontSize * 10 / 13).rounded() }

  var timestampFont: NSFont { .monospacedDigitSystemFont(ofSize: captionSize, weight: .regular) }

  var speakerFont: NSFont { .boldSystemFont(ofSize: captionSize) }

  var volatileBodyFont: NSFont {
    let base = bodyFont
    let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
  }
}

/// Builds the transcript document: one newline-terminated paragraph per
/// segment, laid out as "timestamp <tab> speaker <tab> body" with tab stops
/// and a hanging indent so wrapped lines align under the body column.
/// Pure functions over value inputs, so the whole layer is unit-testable.
enum TranscriptRenderer {
  /// One rendered paragraph as tracked by the incremental updater:
  /// enough to find the first divergent paragraph (`id` + `fingerprint`)
  /// and its character offset (`length`).
  struct RenderedRow {
    let id: UUID
    let fingerprint: Int
    let length: Int
  }

  static let speakerPalette: [NSColor] = [
    .systemBlue, .systemOrange, .systemGreen, .systemPurple,
    .systemPink, .systemTeal, .systemIndigo, .systemBrown,
  ]

  private static let columnGap: CGFloat = 8
  static let badgeBackgroundAlpha: CGFloat = 0.16
  static let badgePaddingHorizontal: CGFloat = 6
  static let badgePaddingVertical: CGFloat = 1
  static let rowTintAlpha: CGFloat = 0.08
  static let rowTintCornerRadius: CGFloat = 6
  /// Text inset from the row-tint edges, applied to every paragraph so
  /// toggling the tint never shifts text.
  static let rowTextInsetHorizontal: CGFloat = 16
  static let rowTextInsetVertical: CGFloat = 7

  /// Palette indexes assigned by first appearance in the session, cycling
  /// through `speakerPalette`. Derived on each update so retroactive
  /// diarization relabeling keeps colors consistent with the current labels.
  static func speakerColorIndexes(
    segments: [TranscriptSegment], volatiles: [VolatileText]
  ) -> [String: Int] {
    var map: [String: Int] = [:]
    let speakers = segments.compactMap(\.speaker) + volatiles.compactMap(\.speaker)
    for speaker in speakers where map[speaker] == nil {
      map[speaker] = map.count % speakerPalette.count
    }
    return map
  }

  /// Session-wide column widths (glyph widths, in points), so every row
  /// starts its body text at the same x regardless of the speaker-name
  /// length. `nil` means the column is absent. A change (a new, longer
  /// speaker appearing) triggers a full re-render.
  struct TranscriptColumns: Equatable {
    var timestamp: CGFloat?
    var speaker: CGFloat?
  }

  static func columns(
    segments: [TranscriptSegment], volatiles: [VolatileText], style: TranscriptStyle
  ) -> TranscriptColumns {
    var columns = TranscriptColumns()
    if style.showsTimestamps {
      // Digits are monospaced, so a widest-case reference (2-digit hour,
      // meridiem where the locale uses one) sizes the column for any time.
      let reference =
        Calendar.current.date(
          from: DateComponents(year: 2000, month: 1, day: 1, hour: 22, minute: 58, second: 58))
        ?? Date()
      columns.timestamp = measure(timestampText(for: reference), font: style.timestampFont)
    }
    let speakers = Set(segments.compactMap(\.speaker) + volatiles.compactMap(\.speaker))
    columns.speaker = speakers.map { measure($0, font: style.speakerFont) }.max()
    return columns
  }

  static func paragraph(
    for segment: TranscriptSegment, colorIndex: Int?, columns: TranscriptColumns,
    style: TranscriptStyle
  ) -> NSAttributedString {
    composeParagraph(
      timestamp: style.showsTimestamps ? timestampText(for: segment.date) : nil,
      speaker: segment.speaker, colorIndex: colorIndex,
      body: (segment.text, [.font: style.bodyFont, .foregroundColor: NSColor.labelColor]),
      columns: columns, style: style
    )
  }

  static func volatileParagraph(
    for volatile: VolatileText, colorIndex: Int?, columns: TranscriptColumns,
    style: TranscriptStyle
  ) -> NSAttributedString {
    composeParagraph(
      timestamp: nil, ellipsis: true,
      speaker: volatile.speaker, colorIndex: colorIndex,
      body: (
        volatile.text,
        [.font: style.volatileBodyFont, .foregroundColor: NSColor.secondaryLabelColor]
      ),
      columns: columns, style: style
    )
  }

  private static func timestampText(for date: Date) -> String {
    date.formatted(.dateTime.hour().minute().second())
  }

  private static func measure(_ text: String, font: NSFont) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
  }

  /// Change detector for an already-rendered paragraph. Includes the color
  /// index because relabeling an earlier segment can shift the first-
  /// appearance palette assignment of later ones. The date is immutable and
  /// style changes trigger a full rebuild, so neither is hashed.
  static func fingerprint(of segment: TranscriptSegment, colorIndex: Int?) -> Int {
    var hasher = Hasher()
    hasher.combine(segment.text)
    hasher.combine(segment.speaker)
    hasher.combine(colorIndex)
    return hasher.finalize()
  }

  /// First index at which the rendered rows no longer reflect `segments`,
  /// or `nil` when they match exactly. Pure appends diverge at `rows.count`;
  /// a retroactive relabel or split diverges at the first changed paragraph.
  static func firstDivergentIndex(
    rows: [RenderedRow], segments: [TranscriptSegment], colorIndexes: [String: Int]
  ) -> Int? {
    let shared = min(rows.count, segments.count)
    for i in 0..<shared {
      let segment = segments[i]
      let colorIndex = segment.speaker.flatMap { colorIndexes[$0] }
      if rows[i].id != segment.id
        || rows[i].fingerprint != fingerprint(of: segment, colorIndex: colorIndex)
      {
        return i
      }
    }
    return rows.count == segments.count ? nil : shared
  }

  private static func rowTint(colorIndex: Int?, style: TranscriptStyle) -> NSColor? {
    guard style.rowTintEnabled, let colorIndex else { return nil }
    return speakerPalette[colorIndex]
  }

  private static func composeParagraph(
    timestamp: String?, ellipsis: Bool = false,
    speaker: String?, colorIndex: Int?,
    body: (String, [NSAttributedString.Key: Any]),
    columns: TranscriptColumns,
    style: TranscriptStyle
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var tabStops: [NSTextTab] = []
    var firstLineIndent = rowTextInsetHorizontal
    var x = rowTextInsetHorizontal

    // Timestamp column (the volatile line's ellipsis lives in it too).
    if let timestampWidth = columns.timestamp {
      if let timestamp {
        result.append(
          NSAttributedString(
            string: timestamp,
            attributes: [
              .font: style.timestampFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
      } else if ellipsis {
        result.append(
          NSAttributedString(
            string: "…",
            attributes: [.font: style.bodyFont, .foregroundColor: NSColor.tertiaryLabelColor]))
      }
      result.append(NSAttributedString(string: "\t", attributes: [.font: style.timestampFont]))
      x += timestampWidth + columnGap
      tabStops.append(NSTextTab(textAlignment: .left, location: x))
    } else if ellipsis {
      // No timestamp column: the ellipsis gets its own little column. The
      // volatile line's remaining columns shift right of the finalized
      // rows' — acceptable for the transient in-progress line.
      result.append(
        NSAttributedString(
          string: "…\t",
          attributes: [.font: style.bodyFont, .foregroundColor: NSColor.tertiaryLabelColor]))
      x += measure("…", font: style.bodyFont) + columnGap
      tabStops.append(NSTextTab(textAlignment: .left, location: x))
    }

    // Speaker column, sized by the widest name in the session so every body
    // starts at the same x. The capsule extends `badgePaddingHorizontal`
    // beyond the glyphs on both sides; keep it clear of the neighbors.
    if let speakerWidth = columns.speaker {
      if tabStops.isEmpty {
        firstLineIndent += badgePaddingHorizontal
        x = firstLineIndent
      } else {
        x += badgePaddingHorizontal
        tabStops[tabStops.count - 1] = NSTextTab(textAlignment: .left, location: x)
      }
      if let speaker {
        result.append(
          NSAttributedString(
            string: speaker, attributes: speakerAttributes(colorIndex: colorIndex, style: style)))
      }
      result.append(NSAttributedString(string: "\t", attributes: [.font: style.speakerFont]))
      x += speakerWidth + badgePaddingHorizontal + columnGap
      tabStops.append(NSTextTab(textAlignment: .left, location: x))
    }

    result.append(NSAttributedString(string: body.0 + "\n", attributes: body.1))

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = style.lineSpacing
    // Entry spacing plus room for the tint's vertical padding above and
    // below the text (the tint rect expands into this gap when drawn).
    // TextKit places `lineSpacing` above the next paragraph's first line
    // too, so subtract it here to keep the visual entry gap independent of
    // the line-spacing setting.
    paragraphStyle.paragraphSpacing = max(
      0, style.entrySpacing + 2 * rowTextInsetVertical - style.lineSpacing)
    paragraphStyle.tabStops = tabStops
    paragraphStyle.firstLineHeadIndent = firstLineIndent
    paragraphStyle.headIndent = x
    paragraphStyle.tailIndent = -rowTextInsetHorizontal

    let range = NSRange(location: 0, length: result.length)
    result.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
    if let tint = rowTint(colorIndex: colorIndex, style: style) {
      result.addAttribute(.transcriptRowTint, value: tint, range: range)
    }
    return result
  }

  private static func speakerAttributes(
    colorIndex: Int?, style: TranscriptStyle
  ) -> [NSAttributedString.Key: Any] {
    guard let colorIndex else {
      return [.font: style.speakerFont, .foregroundColor: NSColor.secondaryLabelColor]
    }
    let color = speakerPalette[colorIndex]
    return [
      .font: style.speakerFont,
      .foregroundColor: color,
      .transcriptSpeakerBadge: color,
    ]
  }
}
