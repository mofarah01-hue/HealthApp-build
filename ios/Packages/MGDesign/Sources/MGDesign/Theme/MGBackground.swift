import SwiftUI
import MGContext

/// Paints a theme's `background` token into a given size: a solid colour, or the Satin Emerald ellipse
/// (CSS `radial-gradient(120% 72% at 50% -14%, …)` — radii are fractions of the screen width and height).
public struct MGBackgroundLayer: View {
    private let background: ThemeBackground
    private let size: CGSize

    public init(_ background: ThemeBackground, size: CGSize) {
        self.background = background
        self.size = size
    }

    public var body: some View {
        switch background {
        case .solid(let c):
            c.color.frame(width: size.width, height: size.height)
        case .radial(let stops, let cx, let cy, let rx, let ry):
            // EllipticalGradient with endRadiusFraction 0.5 fills an ellipse inscribed in its frame, so a frame of
            // (2·rx·w) × (2·ry·h) centred at (cx·w, cy·h) reproduces the CSS ellipse exactly. Outside it the last
            // stop continues, which is also the base colour underneath.
            ZStack(alignment: .topLeading) {
                background.lastColor.color
                EllipticalGradient(
                    gradient: Gradient(stops: stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) }),
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                )
                .frame(width: 2 * rx * size.width, height: 2 * ry * size.height)
                .position(x: cx * size.width, y: cy * size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}

/// A fixed, full-screen theme background (sheets, pushed screens that do not scroll).
/// For scrolling screens use `MGScreen`, whose glow scrolls with the content (contrast rule, ThemeColors.swift).
public struct MGBackground: View {
    @Environment(\.mgColors) private var colors

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            MGBackgroundLayer(colors.background,
                              size: CGSize(width: geo.size.width,
                                           height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom))
                .offset(y: -geo.safeAreaInsets.top)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A themed vertical scroll screen.
///
/// - The theme background is attached to the scroll CONTENT, so on Emerald the bright glow sits behind the header
///   and scrolls away with it; body text never lands on the glow (that is the condition `check_contrast.py`
///   verifies: secondary text from content y 140 pt).
/// - Top overscroll shows the background's first colour, bottom overscroll its last.
/// - Bumping `\.mgScrollToTop` scrolls back to the top (tab re-tap, UX §3.1).
/// - Content gets the 20 pt gutters; pass `gutters: false` to lay out edge to edge.
public struct MGScreen<Content: View>: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgScrollToTop) private var scrollToTop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let gutters: Bool
    private let scrollDisabled: Bool
    private let content: Content

    /// `scrollDisabled`: true while a finger is scrubbing a control on the page (the Sundial), so the page does not
    /// scroll under it (round 8, T10021).
    public init(gutters: Bool = true, scrollDisabled: Bool = false, @ViewBuilder content: () -> Content) {
        self.gutters = gutters
        self.scrollDisabled = scrollDisabled
        self.content = content()
    }

    public var body: some View {
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width,
                              height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(MGScreenAnchor.top)
                        content
                    }
                    .padding(.horizontal, gutters ? MGSpace.gutter : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .top) {
                        MGBackgroundLayer(colors.background, size: full)
                            .offset(y: -geo.safeAreaInsets.top)
                            .accessibilityHidden(true)
                    }
                    .background(colors.background.lastColor.color)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(scrollDisabled)
                .background {
                    VStack(spacing: 0) {
                        colors.background.firstColor.color
                        colors.background.lastColor.color
                    }
                    .ignoresSafeArea()
                }
                .onChange(of: scrollToTop) { _, _ in
                    if reduceMotion {
                        proxy.scrollTo(MGScreenAnchor.top, anchor: .top)
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(MGScreenAnchor.top, anchor: .top) }
                    }
                }
            }
        }
    }
}

enum MGScreenAnchor: Hashable {
    case top
}
