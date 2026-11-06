import SwiftUI
import MGContext

// ARCHITECTURE §4.8: `.mgTheme(_ name: ThemeName)` view modifier + `@Environment(\.mgTheme)`.
// Views read `@Environment(\.mgColors)` for the resolved palette.

private struct MGThemeKey: EnvironmentKey {
    static let defaultValue: ThemeName = .cream
}

private struct MGScrollToTopKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private struct MGQuietHapticsKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct MGSendKey: EnvironmentKey {
    static let defaultValue: (UIIntent) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The theme the context engine chose (UX §1.1). Default: cream.
    public var mgTheme: ThemeName {
        get { self[MGThemeKey.self] }
        set { self[MGThemeKey.self] = newValue }
    }

    /// The resolved colour tokens of `mgTheme`.
    public var mgColors: ThemeColors {
        Theme.colors(for: mgTheme)
    }

    /// Bump this counter (e.g. on a tab re-tap, UX §3.1) and every `MGScreen` below scrolls to the top.
    public var mgScrollToTop: Int {
        get { self[MGScrollToTopKey.self] }
        set { self[MGScrollToTopKey.self] = newValue }
    }

    /// The screen's intent handler, for views whose frozen signature has no `send:` (e.g. `SundialView(state:)`
    /// reads it for callout taps, UX §10). Default: does nothing.
    public var mgSend: (UIIntent) -> Void {
        get { self[MGSendKey.self] }
        set { self[MGSendKey.self] = newValue }
    }

    /// True during Night and Late night: no haptics (UX §1.4).
    public var mgQuietHaptics: Bool {
        get { self[MGQuietHapticsKey.self] }
        set { self[MGQuietHapticsKey.self] = newValue }
    }
}

extension View {
    /// Applies a theme to this subtree: tokens, system colour scheme (so system controls and materials match),
    /// tint, and the 1.2 s cross-fade when the theme changes (instant under Reduce Motion, UX §1.1).
    public func mgTheme(_ name: ThemeName) -> some View {
        modifier(MGThemeModifier(name: name))
    }
}

struct MGThemeModifier: ViewModifier {
    let name: ThemeName
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let colors = Theme.colors(for: name)
        return content
            .environment(\.mgTheme, name)
            .environment(\.colorScheme, colors.isDark ? .dark : .light)
            .tint(colors.ink.color)
            .animation(MGMotion.themeChange(reduceMotion: reduceMotion), value: name)
    }
}
