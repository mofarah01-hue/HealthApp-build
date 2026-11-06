import SwiftUI
import MGContext

// r8h G1 (UI-SCRUB-B §3): a half-typed note or food entry used to vanish when its row closed (another row opened, a tab
// change, a rebuild). Drafts now live here, keyed by the row id and a field name, and are cleared when the entry is saved
// (`LogFormContext.commit`). In memory only: they are text the user has not saved, so nothing is written to disk.
// Capped (200 fields, 2000 characters each) so a runaway field cannot grow without limit.

final class LogDrafts: @unchecked Sendable {
    static let shared = LogDrafts()

    private let lock = NSLock()
    private var store: [String: String] = [:]
    private static let maxFields = 200
    private static let maxLength = 2000

    private func key(_ row: String, _ field: String) -> String { row + "/" + field }

    func get(row: String, field: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key(row, field)]
    }

    func set(row: String, field: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        let k = key(row, field)
        if text.isEmpty { store[k] = nil; return }
        if store[k] == nil && store.count >= Self.maxFields { return }
        store[k] = String(text.prefix(Self.maxLength))
    }

    /// Drop every draft of one row (called when it is saved).
    func clear(row: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = row + "/"
        store = store.filter { !$0.key.hasPrefix(prefix) }
    }
}

private struct KeepsDraft: ViewModifier {
    @Binding var text: String
    let row: String
    let field: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                if text.isEmpty, let saved = LogDrafts.shared.get(row: row, field: field) { text = saved }
            }
            .onChange(of: text) { _, new in
                LogDrafts.shared.set(row: row, field: field, text: new)
            }
    }
}

extension View {
    /// Keep what is typed in `text` when the row closes; it is restored when the form opens again.
    func keepsDraft(_ text: Binding<String>, row: String, field: String) -> some View {
        modifier(KeepsDraft(text: text, row: row, field: field))
    }
}
