import LiveTranscriberCore
import SwiftUI

/// Progress of the diarization model loading in the background, before any
/// session needs it. The download reports real progress; the CoreML load
/// reports none, so it stays indeterminate rather than freezing a bar
/// halfway.
struct DiarizerLoadIndicator: View {
  let progress: DiarizerModelLoadProgress
  /// Compact form for the toolbar: the spinner alone, with the label as its
  /// tooltip.
  var iconOnly = false

  var body: some View {
    if iconOnly {
      ProgressView()
        .controlSize(.small)
        .help(label)
    } else {
      HStack(spacing: 8) {
        switch progress.phase {
        case .downloading(let fraction):
          ProgressView(value: fraction)
            .controlSize(.small)
            .frame(width: 60)
        case .preparing:
          ProgressView()
            .controlSize(.small)
        }
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var label: String {
    switch progress.phase {
    case .downloading(let fraction):
      String(localized: "Downloading the speaker model… \(Int(fraction * 100))%")
    case .preparing:
      String(localized: "Preparing the speaker model…")
    }
  }
}
