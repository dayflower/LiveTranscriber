import SwiftUI

/// Icon-plus-bar input level readout. Speech RMS rarely exceeds ~0.3, so the
/// value is scaled up for a useful visual range.
struct InputLevelGauge: View {
  let level: Float
  let icon: String
  let width: CGFloat

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption)
        .foregroundStyle(.secondary)
      Gauge(value: min(1, Double(level) * 3)) {
        EmptyView()
      }
      .gaugeStyle(.accessoryLinearCapacity)
      .tint(.green)
      .frame(width: width)
    }
  }
}
