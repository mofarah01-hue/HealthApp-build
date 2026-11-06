import SwiftUI
import MGContext
import MGDesign

/// "Vape hit 10:42 · Undo" (UX §10) and "Removed · Undo" (UX §7: Undo; r8h G5: 8 s, longer while VoiceOver is on). Local to the Log tab: it only
/// remembers what to say and which intents undo it; the data itself changes through the intents.
struct LogToast: Identifiable, Equatable {
    let id: UUID
    var message: String
    /// Sent when Undo is tapped. Empty = no Undo button.
    var undo: [UIIntent]

    init(message: String, undo: [UIIntent]) {
        self.id = UUID()
        self.message = message
        self.undo = undo
    }

    /// How long it stays (seconds). r8h G5: 8 (was 5) so slow readers and Switch Control users can reach Undo.
    static let lifetime: TimeInterval = 8
    /// While VoiceOver reads the message and moves to the button, it stays longer.
    static let lifetimeVoiceOver: TimeInterval = 20
}

struct LogToastView: View {
    let toast: LogToast
    let onUndo: () -> Void

    init(toast: LogToast, onUndo: @escaping () -> Void) {
        self.toast = toast
        self.onUndo = onUndo
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: MGSpace.m) {
            Text(toast.message)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !toast.undo.isEmpty {
                Button(action: onUndo) {
                    Text("Undo")
                        .mgFont(.button)
                        .foregroundStyle(colors.ink.color)
                        .frame(minWidth: MGSpace.tapTarget, minHeight: MGSpace.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MGPressButtonStyle())
                .accessibilityHint("Undoes this for the next few seconds")
            }
        }
        .padding(.leading, MGSpace.l)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .mgSurface(.card, radius: MGRadius.pill)
        .mgShadow(.raised)
        .padding(.horizontal, MGSpace.gutter)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Recently removed (R9f, UI-SCRUB-B G5)

/// An entry the user removed from the list, kept here so Undo outlasts the toast. Removing is soft (the entry stays in the
/// history), so `.undoRemove(id:)` still works later. Remembered while the Log tab is alive; gone after a restart.
struct LogRemovedEntry: Identifiable, Equatable {
    let id: UUID
    let title: String

    /// The most kept.
    static let keep = 5

    /// The removed entry a toast stands for, or nil when it is some other toast ("Vape hit 10:42", a time shift).
    init?(toast: LogToast) {
        guard toast.undo.count == 1, case .undoRemove(let id) = toast.undo[0], toast.message.hasPrefix("Removed ") else {
            return nil
        }
        self.id = id
        self.title = String(toast.message.dropFirst("Removed ".count))
    }

    /// `list` with this entry first (an older copy of it dropped), at most `keep` long.
    static func adding(_ entry: LogRemovedEntry, to list: [LogRemovedEntry]) -> [LogRemovedEntry] {
        Array(([entry] + list.filter { $0.id != entry.id }).prefix(keep))
    }
}

/// "Recently removed": one row per entry with a Restore button. Only drawn when there is something in it.
struct LogRecentlyRemovedView: View {
    let items: [LogRemovedEntry]
    let canAct: Bool
    let restore: (LogRemovedEntry) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Recently removed", note: "kept in your history; Restore puts it back")
                ForEach(items) { item in
                    HStack(spacing: MGSpace.m) {
                        Text(item.title)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { restore(item) } label: {
                            Text("Restore")
                                .mgFont(.button)
                                .foregroundStyle(colors.ink.color)
                                .frame(minWidth: MGSpace.tapTarget, minHeight: MGSpace.tapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(MGPressButtonStyle())
                        .disabled(!canAct)
                        .accessibilityLabel("Restore \(item.title)")
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                    }
                }
            }
        }
    }
}
