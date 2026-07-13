import SwiftUI

/// Popover content for entering an arbitrary estimated duration in minutes.
/// Used by the new-session sheet and the recording toolbar menu.
struct CustomDurationEntry: View {
  @State private var minutes: Int
  private let onCommit: (Int) -> Void

  init(minutes: Int, onCommit: @escaping (Int) -> Void) {
    _minutes = State(initialValue: minutes)
    self.onCommit = onCommit
  }

  var body: some View {
    HStack(spacing: 8) {
      TextField("Minutes", value: $minutes, format: .number)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 64)
      Text("min")
      Button("Set") { onCommit(minutes) }
        .keyboardShortcut(.defaultAction)
        .disabled(minutes < 1)
    }
    .padding(12)
  }
}
