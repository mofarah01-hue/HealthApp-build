import SwiftUI

// R8e (UI-SCRUB-B X3): a switch that moves at once. The presenters own the truth, but their new state comes back only after
// the intent ran (0.5 s on Live; longer when a setting is saved and the compute engine asked), and until then a plain
// state-driven switch flipped back, looked broken and let a second tap send a second intent.
//
// This one shows the new position as soon as it is tapped, with a small sending mark; it goes back to following the state
// when the state arrives (or after 3 s, if it never changes: a refused change then shows the real position). A tap while
// the first is still sending is ignored.
//
// WRITTEN, NOT COMPILED.

public struct OptimisticToggle<Label: View>: View {
    private let isOn: Bool
    private let onChange: (Bool) -> Void
    private let label: Label

    /// The position shown while a change is on its way; nil = follow `isOn`.
    @State private var shown: Bool?
    /// Counts taps that started a send; `.task(id:)` restarts the 3 s reset from each.
    @State private var ticket = 0

    /// `onChange` gets the NEW value; `isOn` is the presenter's state.
    public init(isOn: Bool, onChange: @escaping (Bool) -> Void, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.onChange = onChange
        self.label = label()
    }

    private var sending: Bool { shown != nil }

    public var body: some View {
        Toggle(isOn: Binding(get: { shown ?? isOn }, set: { new in
            guard shown == nil else { return }          // a second tap while the first is sending
            shown = new
            ticket += 1
            onChange(new)
        })) {
            HStack(spacing: 8) {
                label
                if sending {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: isOn) { _, _ in shown = nil }      // the state arrived
        .task(id: ticket) {
            guard ticket > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { shown = nil }
        }
    }
}
