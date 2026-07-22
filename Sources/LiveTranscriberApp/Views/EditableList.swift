import SwiftUI

/// A bordered table with the standard macOS add/remove bar beneath it.
///
/// The list scrolls internally, so a settings tab hosting one keeps a fixed
/// height no matter how many items are registered.
struct EditableList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  var height: CGFloat = 150
  let placeholder: LocalizedStringKey
  let addLabel: LocalizedStringKey
  let removeLabel: LocalizedStringKey
  let onAdd: () -> Void
  let onRemove: (Item) -> Void
  @ViewBuilder let row: (Item) -> Row

  @State private var selection: Item.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      List(items, selection: $selection) { item in
        row(item)
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))
      .frame(height: height)
      .overlay {
        if items.isEmpty {
          Text(placeholder)
            .foregroundStyle(.secondary)
        }
      }
      .onDeleteCommand(perform: removeSelected)

      HStack(spacing: 8) {
        Button(action: onAdd) {
          Image(systemName: "plus")
        }
        .accessibilityLabel(addLabel)

        Button(action: removeSelected) {
          Image(systemName: "minus")
        }
        .disabled(selectedItem == nil)
        .accessibilityLabel(removeLabel)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .padding(.leading, 4)
    }
  }

  private var selectedItem: Item? {
    selection.flatMap { id in items.first { $0.id == id } }
  }

  private func removeSelected() {
    guard let item = selectedItem else { return }
    selection = nil
    onRemove(item)
  }
}
