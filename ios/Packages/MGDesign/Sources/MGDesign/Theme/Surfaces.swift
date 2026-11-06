import SwiftUI

/// Which filled shape a surface is.
public enum MGSurfaceKind: Sendable {
    /// Cards, moment card, status chip — the `surface` token (hairline-bordered paper on Day, glass on Night).
    case card
    /// A metric tile: the card fill at radius 14 (`MGRadius.tile`).
    case tile
    /// The peek (one-question card).
    case peek
    /// Answer buttons and chips.
    case chip
}

/// Fills the view's background with a theme surface, clipped to a continuous rounded rectangle.
/// Glass = backdrop material + tint + white highlight + 1 pt border (Satin Emerald). Under Reduce Transparency
/// glass becomes the opaque `sheet` colour with the same border.
public struct MGSurfaceModifier: ViewModifier {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let kind: MGSurfaceKind
    private let radius: CGFloat
    private let shadow: Bool

    /// `radius` nil = the kind's own (tile 14, everything else 20).
    public init(kind: MGSurfaceKind, radius: CGFloat?, shadow: Bool) {
        self.kind = kind
        self.radius = radius ?? (kind == .tile ? MGRadius.tile : MGRadius.card)
        self.shadow = shadow
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background { fill(shape) }
            .clipShape(shape)
            .mgShadow(shadow ? .raised : .none)
    }

    @ViewBuilder
    private func fill(_ shape: RoundedRectangle) -> some View {
        switch kind {
        case .chip:
            shape.fill(colors.chip.color)
        case .peek:
            if colors.isDark && !reduceTransparency {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(colors.peek.color)
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            } else {
                ZStack {
                    shape.fill(colors.isDark ? colors.sheet.color : colors.peek.color)
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            }
        case .card, .tile:
            switch colors.surface {
            case .solid(let c, let border):
                ZStack {
                    shape.fill(c.color)
                    if let border { shape.strokeBorder(border.color, lineWidth: 1) }
                }
            case .glass(let tint, let top, let bottom, let border, _):
                if reduceTransparency {
                    ZStack {
                        shape.fill(colors.sheet.color)
                        shape.strokeBorder(border.color, lineWidth: 1)
                    }
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(tint.color)
                        shape.fill(LinearGradient(colors: [Color.white.opacity(top), Color.white.opacity(bottom)],
                                                  startPoint: .top, endPoint: .bottom))
                        shape.strokeBorder(border.color, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var borderColor: Color {
        switch colors.surface {
        case .glass(_, _, _, let border, _): return border.color
        case .solid(_, let border): return (border ?? colors.rule).color
        }
    }
}

extension View {
    /// `content.mgSurface()` — a card-shaped theme surface behind the view.
    public func mgSurface(_ kind: MGSurfaceKind = .card, radius: CGFloat? = nil, shadow: Bool = false) -> some View {
        modifier(MGSurfaceModifier(kind: kind, radius: radius, shadow: shadow))
    }
}

/// A padded card on the theme surface (UX §1.4: radius 20, inset 16).
public struct MGCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = MGSpace.cardInset, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mgSurface(.card, radius: MGRadius.card)
    }
}
