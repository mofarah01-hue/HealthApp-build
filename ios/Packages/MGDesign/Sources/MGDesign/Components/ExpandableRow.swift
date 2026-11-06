import SwiftUI
import MGContext

/// A round letter badge for a row: the letter and which accent tints it.
public struct RowBadge: Hashable, Sendable {
    public let letter: String
    public let accent: InkTone

    public init(_ letter: String, accent: InkTone) {
        self.letter = letter
        self.accent = accent
    }
}

/// A one-tap button on the right of a row ("Took it", "Start").
public struct RowAction {
    public let title: String
    public let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// A row that opens in place (UX §10: tap a row with a chevron → opens in place; tap again closes).
/// Frozen signature (ARCHITECTURE §4.8): `ExpandableRow(title:detail:receipt:isOpen:content:)`; `badge` and
/// `action` are optional extras for the Now rows. Rows are at least 56 pt tall; the chevron turns 90° when open.
public struct ExpandableRow<Content: View>: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let detail: String?
    private let receipt: Receipt?
    private let receiptNote: String?
    private let badge: RowBadge?
    private let action: RowAction?
    @Binding private var isOpen: Bool
    private let content: Content
    private let hasContent: Bool

    public init(title: String, detail: String?, receipt: Receipt?, receiptNote: String? = nil, badge: RowBadge? = nil,
                action: RowAction? = nil, isOpen: Binding<Bool>, hasContent: Bool = true,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.receipt = receipt
        self.receiptNote = receiptNote
        self.badge = badge
        self.action = action
        self._isOpen = isOpen
        self.hasContent = hasContent
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    guard hasContent else { return }
                    withAnimation(MGMotion.expand(reduceMotion: reduceMotion)) { isOpen.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        if let badge { LetterBadge(badge.letter, accent: badge.accent) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail {
                                Text(detail)
                                    .mgFont(.detail)
                                    .foregroundStyle(colors.ink2.color)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ReceiptLine(receipt: receipt, note: receiptNote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.top, 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // r8h E4: the chevron is part of the Button, so tapping the arrow opens the row.
                        if hasContent {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(hasContent ? (isOpen ? "open" : "closed") : "")
                .accessibilityHint(hasContent ? (isOpen ? "Closes this row" : "Opens this row in place") : "")

                if let action {
                    MGButton(action.title, style: .filled, action: action.action)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: MGSpace.rowMinHeight)

            if isOpen && hasContent {
                content
                    .padding(.leading, badge == nil ? 0 : 50)    // 40 pt badge + 10 pt gap
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
    }
}

extension ExpandableRow where Content == EmptyView {
    /// A row that does not open (no chevron).
    public init(title: String, detail: String?, receipt: Receipt?, receiptNote: String? = nil, badge: RowBadge? = nil,
                action: RowAction? = nil) {
        self.init(title: title, detail: detail, receipt: receipt, receiptNote: receiptNote, badge: badge,
                  action: action, isOpen: .constant(false), hasContent: false) { EmptyView() }
    }
}
