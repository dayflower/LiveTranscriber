import Foundation
import SwiftUI

/// Maps linear RMS levels onto a dBFS scale for the controls that have to show
/// the noise floor and speech in the same picture: linear, everything below
/// speech collapses into the leftmost few percent of a bar, which makes a
/// squelch threshold impossible to place by eye. Speech runs about -34...-10
/// dB, noise floors below -40 dB.
enum AudioLevelScale {
  /// Bottom of the scale; quieter levels pin here.
  static let floorDB: Double = -60

  static func decibels(_ level: Float) -> Double {
    20 * log10(max(Double(level), 1e-6))
  }

  static func level(fromDecibels decibels: Double) -> Float {
    Float(pow(10, decibels / 20))
  }

  /// Position of `level` on a 0...1 bar spanning `floorDB`...0 dB.
  static func fraction(of level: Float) -> Double {
    min(1, max(0, (decibels(level) - floorDB) / -floorDB))
  }
}

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
