import Foundation

/// Opt-in stderr tracing of the diarization timeline and the speaker
/// assignment it drives, for diagnosing misaligned attribution.
///
/// Enabled by launching with `LT_DIARIZATION_DEBUG=1`; disabled builds pay
/// only the `isEnabled` check because messages are autoclosures. Lines go to
/// stderr via `fputs` (stdio locks internally, so concurrent emitters from
/// the diarizer actor and the main actor stay whole).
public enum DiarizationDebug {
  public static let isEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment["LT_DIARIZATION_DEBUG"] else {
      return false
    }
    return !["", "0", "false", "no"].contains(value.lowercased())
  }()

  public static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    fputs("[diarize] \(message())\n", stderr)
  }

  /// Compact fixed-precision seconds, so columns line up across lines.
  public static func time(_ value: TimeInterval) -> String {
    String(format: "%.2f", value)
  }

  public static func time(_ value: TimeInterval?) -> String {
    value.map(time) ?? "-"
  }

  public static func describe(_ segments: [DiarizedSegment]) -> String {
    guard !segments.isEmpty else { return "-" }
    return segments.map { "\($0.speaker)@\(time($0.audioStart))-\(time($0.audioEnd))" }
      .joined(separator: " ")
  }
}

extension SpeakerLabel: CustomStringConvertible {
  public var description: String {
    switch self {
    case .microphone: "Mic"
    case .appAudio: "App"
    case .diarized(let number): "S\(number)"
    case .named(let name): name
    }
  }
}

extension AudioSource: CustomStringConvertible {
  public var description: String {
    switch self {
    case .microphone: "mic"
    case .appAudio: "app"
    }
  }
}
