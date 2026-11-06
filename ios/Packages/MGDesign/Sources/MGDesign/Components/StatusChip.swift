import SwiftUI
import MGContext

/// Strap dot + battery and sync state in one 32 pt capsule (UX §3.2 row 1); tap → Strap & sync.
/// ARCHITECTURE §4.8: `StatusChip(state:send:)`. Colour is never the only code: the words say the same thing.
/// Text uses `topText` because the chip sits in the header, on the brightest part of the Emerald glow.
public struct StatusChip: View {
    @Environment(\.mgColors) private var colors
    private let state: StatusChipState
    private let send: (UIIntent) -> Void

    public init(state: StatusChipState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        Button { send(state.intent) } label: {
            // Two status groups side by side; at large type they stack and wrap instead of clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    group(state.strapTone, state.strapText)
                    group(state.syncTone, state.syncText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    group(state.strapTone, state.strapText)
                    group(state.syncTone, state.syncText)
                }
            }
            .mgFont(MGTextStyle(family: .mono, size: 12, lineHeight: 15, weight: .medium, relativeTo: .caption,
                                maxScale: 1.6))
            .foregroundStyle(colors.topText.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .mgSurface(.card, radius: 16)
            .frame(minHeight: MGSpace.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint("Opens strap and sync")
    }

    private func group(_ tone: StatusTone, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(colors.status(tone).color).frame(width: 7, height: 7)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
