import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Round 5 (C21): the "From your list" dropdown in a Log form. The items are Mo's own Settings lists (PresetLists); an
/// empty list says so and points at Settings instead of showing an empty menu. Picking only fills the form's fields; what
/// is logged is the normal event the form already saves, so it syncs like any other log.
struct LogFromYourList<Item: Identifiable>: View {
    let items: [Item]
    let label: (Item) -> String
    let pick: (Item) -> Void

    init(items: [Item], label: @escaping (Item) -> String, pick: @escaping (Item) -> Void) {
        self.items = items
        self.label = label
        self.pick = pick
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        if items.isEmpty {
            LogHint("Your list is empty. Add items in Preferences › Preset lists.")
        } else {
            Menu {
                ForEach(items) { item in
                    Button(label(item)) { pick(item) }
                }
            } label: {
                Text("From your list ▾")
                    .mgFont(.detail)
                    .foregroundStyle(colors.focus.color)
                    .frame(minHeight: MGSpace.tapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Pick from your list")
        }
    }
}
