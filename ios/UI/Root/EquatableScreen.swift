import SwiftUI
import MGContext

// R7 / T23 (Mo: "lags on scrolling"): a view that holds a closure (`send:`) can't be compared by SwiftUI, so every change
// of anything the model publishes (a note, the working line, the once-a-second Live state) made RootView re-run the body
// of all four tab screens, hidden ones included. This wraps a screen so it is re-run only when its own state changed:
// the closures are left out of the comparison (they only call the same model).
//
// WRITTEN, NOT COMPILED.

struct EquatableScreen<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    let content: () -> Content

    init(_ key: Key, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    static func == (lhs: EquatableScreen<Key, Content>, rhs: EquatableScreen<Key, Content>) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View { content() }
}

/// LogView's two inputs.
struct LogScreenKey: Equatable {
    let state: LogState
    let catalogue: LogCatalogue
}
