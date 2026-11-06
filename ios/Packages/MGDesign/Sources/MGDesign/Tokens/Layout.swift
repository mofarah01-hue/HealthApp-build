import SwiftUI

// Space, shape, shadow, motion and haptics — UX-SPEC §1.4, values per ui-pitch/DESIGN-TOKENS.md §3–§5 (0.6).

public enum MGSpace {
    /// 4 pt grid.
    public static let grid: CGFloat = 4
    /// Screen gutter.
    public static let gutter: CGFloat = 20
    /// Gap between sections (0.6: was 24).
    public static let section: CGFloat = 28
    /// Padding inside cards.
    public static let cardInset: CGFloat = 16
    /// Padding inside metric tiles.
    public static let tileInset: CGFloat = 12
    /// Stack gaps.
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    /// Minimum tap target.
    public static let tapTarget: CGFloat = 44
    /// Minimum row height.
    public static let rowMinHeight: CGFloat = 56
    /// Log row height.
    public static let logRowHeight: CGFloat = 72
}

public enum MGRadius {
    public static let card: CGFloat = 20
    public static let peek: CGFloat = 24
    /// A 44 pt capsule (0.6: was 18).
    public static let pill: CGFloat = 22
    /// Detail sheets.
    public static let sheet: CGFloat = 24
    /// Metric tiles.
    public static let tile: CGFloat = 14
    /// Tag pills.
    public static let tag: CGFloat = 6
    public static let chip: CGFloat = 10
    /// Moment card (prototype `.moment`).
    public static let moment: CGFloat = 18
    /// Floating tab bar on Emerald (Satin Emerald); Cream's tab bar has no radius.
    public static let tabBarFloating: CGFloat = 33
}

/// Drop shadow in the theme's `shadow` colour (DESIGN-TOKENS §4). Cards and tiles use `.none` (Day: hairline border,
/// Night: glass border). Apply with `.mgShadow(.raised)`.
public struct MGShadow: Equatable, Sendable {
    public struct Spec: Equatable, Sendable {
        public let radius: CGFloat
        public let y: CGFloat
        /// Multiplies the colour's own alpha.
        public let alpha: Double
    }

    public let day: Spec
    public let night: Spec

    public static let none = MGShadow(day: Spec(radius: 0, y: 0, alpha: 0), night: Spec(radius: 0, y: 0, alpha: 0))
    /// Peek, moment card, toast, scrub label, ring legend chip while pressed.
    public static let raised = MGShadow(day: Spec(radius: 20, y: 8, alpha: 0.8), night: Spec(radius: 24, y: 10, alpha: 1))
    /// Night floating tab bar.
    public static let floating = MGShadow(day: Spec(radius: 30, y: 12, alpha: 1), night: Spec(radius: 30, y: 12, alpha: 1))
}

private struct MGShadowModifier: ViewModifier {
    @Environment(\.mgColors) private var colors
    let shadow: MGShadow

    func body(content: Content) -> some View {
        let spec = colors.isDark ? shadow.night : shadow.day
        return content.shadow(color: spec.alpha == 0 ? .clear : colors.shadow.opacity(spec.alpha).color,
                              radius: spec.radius, x: 0, y: spec.y)
    }
}

extension View {
    public func mgShadow(_ shadow: MGShadow) -> some View {
        modifier(MGShadowModifier(shadow: shadow))
    }
}

/// Every animation in the app goes through here so Reduce Motion is honoured in one place:
/// with Reduce Motion on, each becomes a 150 ms fade (or nothing).
public enum MGMotion {
    /// Row / strip expand-collapse: spring 0.35 / 0.85 (chevron rotates 90°).
    public static func expand(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Peek in / out: slide 24 pt + fade, 280 ms ease-out.
    public static func peek(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.28)
    }

    /// The peek appears this long after Today settles.
    public static let peekDelay: TimeInterval = 1.2
    /// Peek slide distance.
    public static let peekOffset: CGFloat = 24

    /// Moment card: fade + height, 250 ms.
    public static func moment(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25)
    }

    /// Theme change at a phase boundary: 1.2 s cross-fade; instant under Reduce Motion (UX §1.1).
    public static func themeChange(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.2)
    }

    /// Live pulse dot scale on each beat (1 → 1.18 → 1). Under Reduce Motion the dot stays still.
    public static let pulseScale: CGFloat = 1.18

    /// Inner ring fill: ease-out 0.6 s, each ring 0.05 s after the one outside it (`index` 0 = outermost). Reduce
    /// Motion: no sweep, the final value at once (nil).
    public static func ringSweep(reduceMotion: Bool, index: Int) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.05 * Double(index))
    }

    /// Tile values: pair with `.contentTransition(.numericText())`. Reduce Motion: a plain swap (nil).
    public static func numeric(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }

    /// A short physical response while an action button is held. Reduce Motion keeps the button still.
    public static let buttonPressScale: CGFloat = 0.96
}

/// Press animation for action buttons. Haptics stay on the owning logging view so quiet hours still apply.
public struct MGPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : MGMotion.buttonPressScale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// UX §1.4 haptics: one-tap log → light impact; entry saved → success; nothing else in-app; none at Night /
/// Late night (pass `quiet`). Declarative (`sensoryFeedback`, iOS 17), so no UIKit generator and no actor hops:
/// bump a counter when the tap happens and attach the modifier to the view that owns the counter.
extension View {
    public func mgLogHaptic<T: Equatable>(trigger: T, quiet: Bool) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: trigger) { _, _ in !quiet }
    }

    public func mgSavedHaptic<T: Equatable>(trigger: T, quiet: Bool) -> some View {
        sensoryFeedback(.success, trigger: trigger) { _, _ in !quiet }
    }
}
