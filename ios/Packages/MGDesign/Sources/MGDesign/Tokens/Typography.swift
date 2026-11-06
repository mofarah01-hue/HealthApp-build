import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Type scale — UX-SPEC §1.3, fonts per ARCHITECTURE D14 / BRIEF default 8:
// system fonts in the first build (New York serif for headlines via the .serif design, SF for text, SF Mono for
// kickers and receipts), behind ONE switch: `Typography.mode`. Flip it to `.bundled` once Fraunces and IBM Plex
// (SIL OFL) are added to the app bundle; until a font file is found the system face is used, so the switch is safe.
//
// Dynamic Type: every style scales with its UX `relativeTo` text style through @ScaledMetric, capped at
// `maxScale` so a 96 pt hero number cannot grow to 180 pt at the largest accessibility size.

public enum TypographyMode: String, Sendable {
    /// New York / SF / SF Mono (first build).
    case system
    /// Fraunces / IBM Plex Sans / IBM Plex Mono, if the font files are in the bundle.
    case bundled
}

public enum Typography {
    /// THE switch (D14). Set once at launch, before the first view renders.
    public static var mode: TypographyMode = .system
}

public enum MGFontFamily: Sendable {
    case serif, sans, mono

    var systemDesign: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .mono: return .monospaced
        }
    }
}

public enum MGFontWeight: Sendable {
    case light, regular, medium, semibold

    var fontWeight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }

    /// PostScript-name suffix for the bundled families (verify against the font files when they are added).
    var bundledSuffix: String {
        switch self {
        case .light: return "Light"
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "SemiBold"
        }
    }
}

/// One row of the UX §1.3 type table.
public struct MGTextStyle {
    public let family: MGFontFamily
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: MGFontWeight
    public let relativeTo: Font.TextStyle
    /// Letter spacing in em (0.14 em for kickers).
    public let trackingEm: CGFloat
    public let uppercase: Bool
    /// Tabular figures (numbers line up in columns and do not jiggle when they change).
    public let tabular: Bool
    /// Largest Dynamic Type growth allowed, as a multiple of `size`.
    public let maxScale: CGFloat

    public init(family: MGFontFamily, size: CGFloat, lineHeight: CGFloat, weight: MGFontWeight,
                relativeTo: Font.TextStyle, trackingEm: CGFloat = 0, uppercase: Bool = false,
                tabular: Bool = false, maxScale: CGFloat = 2.2) {
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.relativeTo = relativeTo
        self.trackingEm = trackingEm
        self.uppercase = uppercase
        self.tabular = tabular
        self.maxScale = maxScale
    }

    /// The font at an already-scaled point size.
    public func font(size scaled: CGFloat) -> Font {
        var font: Font
        if Typography.mode == .bundled, let name = bundledFontName, MGTextStyle.fontExists(name) {
            font = .custom(name, fixedSize: scaled)    // fixedSize: scaling already happened via @ScaledMetric
        } else {
            font = .system(size: scaled, weight: weight.fontWeight, design: family.systemDesign)
        }
        if tabular { font = font.monospacedDigit() }
        return font
    }

    var bundledFontName: String? {
        switch family {
        case .serif: return "Fraunces-\(weight.bundledSuffix)"
        case .sans: return weight == .regular ? "IBMPlexSans" : "IBMPlexSans-\(weight.bundledSuffix)"
        case .mono: return weight == .regular ? "IBMPlexMono" : "IBMPlexMono-\(weight.bundledSuffix)"
        }
    }

    static func fontExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: name, size: 12) != nil
        #else
        return false
        #endif
    }
}

extension MGTextStyle {
    // 0.6 type table (ui-pitch/DESIGN-TOKENS.md §2; UX §1.3 before). Weights: 560 → semibold, 300 → light.
    public static let verdict = MGTextStyle(family: .serif, size: 34, lineHeight: 38, weight: .semibold,
                                            relativeTo: .largeTitle, trackingEm: -0.02, maxScale: 1.6)
    public static let title = MGTextStyle(family: .serif, size: 30, lineHeight: 34, weight: .semibold,
                                          relativeTo: .title, trackingEm: -0.02, maxScale: 1.6)
    /// Detail-sheet title ("9.4 of 21").
    public static let sheetTitle = MGTextStyle(family: .serif, size: 28, lineHeight: 32, weight: .semibold,
                                               relativeTo: .title, trackingEm: -0.02, maxScale: 1.6)
    public static let headline = MGTextStyle(family: .serif, size: 22, lineHeight: 26, weight: .semibold,
                                             relativeTo: .title3, trackingEm: -0.012, maxScale: 1.8)
    public static let heroNumber = MGTextStyle(family: .sans, size: 96, lineHeight: 88, weight: .light,
                                               relativeTo: .largeTitle, trackingEm: -0.03, tabular: true, maxScale: 1.25)
    public static let bigNumber = MGTextStyle(family: .sans, size: 28, lineHeight: 30, weight: .medium,
                                              relativeTo: .title, trackingEm: -0.02, tabular: true, maxScale: 1.6)
    public static let number = MGTextStyle(family: .sans, size: 22, lineHeight: 24, weight: .medium,
                                           relativeTo: .title3, trackingEm: -0.02, tabular: true, maxScale: 1.8)
    public static let body = MGTextStyle(family: .sans, size: 16, lineHeight: 22, weight: .regular,
                                         relativeTo: .body)
    public static let rowTitle = MGTextStyle(family: .sans, size: 17, lineHeight: 22, weight: .semibold,
                                             relativeTo: .headline)
    public static let detail = MGTextStyle(family: .sans, size: 13, lineHeight: 18, weight: .regular,
                                           relativeTo: .subheadline)
    /// Tile labels, chip captions.
    public static let label = MGTextStyle(family: .sans, size: 12, lineHeight: 15, weight: .regular,
                                          relativeTo: .caption, maxScale: 2.0)
    public static let kicker = MGTextStyle(family: .mono, size: 11, lineHeight: 14, weight: .medium,
                                           relativeTo: .caption, trackingEm: 0.14, uppercase: true)
    public static let receipt = MGTextStyle(family: .mono, size: 11, lineHeight: 14, weight: .regular,
                                            relativeTo: .caption2, maxScale: 2.0)
    public static let tab = MGTextStyle(family: .sans, size: 10.5, lineHeight: 13, weight: .medium,
                                        relativeTo: .caption2, maxScale: 1.5)

    // Small additions used by the shared components (sizes from the prototype CSS, raised for 0.6).
    /// Unit beside a number ("bpm", "ms"), always in ink2.
    public static let unit = MGTextStyle(family: .sans, size: 12, lineHeight: 14, weight: .regular,
                                         relativeTo: .caption, maxScale: 2.0)
    /// Button and pill labels (prototype `.btn`, `.pill`).
    public static let button = MGTextStyle(family: .sans, size: 15, lineHeight: 20, weight: .semibold,
                                           relativeTo: .subheadline, maxScale: 1.8)
    /// Words where a vital is shown as words ("in range").
    public static let wordValue = MGTextStyle(family: .sans, size: 15, lineHeight: 20, weight: .medium,
                                              relativeTo: .body)
    /// Meaning tag: est. · raw · decoded, untested · research.
    public static let tag = MGTextStyle(family: .mono, size: 10, lineHeight: 12, weight: .medium,
                                        relativeTo: .caption2, trackingEm: 0.02, maxScale: 2.0)

    // Sundial (0.6): hour labels, hub text, corner callouts. The 1.3 cap is the dial corner value; a grid of
    // ring chips builds its own copy with maxScale 2.0 (DESIGN-TOKENS §2).
    public static let dialHour = MGTextStyle(family: .sans, size: 11, lineHeight: 13, weight: .medium,
                                             relativeTo: .caption2, trackingEm: 0.02, tabular: true, maxScale: 1.3)
    public static let hubKicker = MGTextStyle(family: .mono, size: 10, lineHeight: 12, weight: .medium,
                                              relativeTo: .caption2, trackingEm: 0.12, uppercase: true, maxScale: 1.3)
    /// Hub time. Views apply `minimumScaleFactor(0.65)`.
    public static let hubBig = MGTextStyle(family: .sans, size: 26, lineHeight: 28, weight: .light,
                                           relativeTo: .title2, trackingEm: -0.02, tabular: true, maxScale: 1.3)
    public static let hubDetail = MGTextStyle(family: .sans, size: 12, lineHeight: 15, weight: .regular,
                                              relativeTo: .caption, maxScale: 1.3)
    public static let calloutValue = MGTextStyle(family: .sans, size: 17, lineHeight: 20, weight: .semibold,
                                                 relativeTo: .headline, trackingEm: -0.01, tabular: true, maxScale: 1.3)
    public static let calloutCaption = MGTextStyle(family: .sans, size: 12, lineHeight: 15, weight: .regular,
                                                   relativeTo: .caption, maxScale: 1.3)
}

/// Applies one `MGTextStyle` with Dynamic Type scaling (capped), tracking, line height and case.
public struct MGTextStyleModifier: ViewModifier {
    private let style: MGTextStyle
    @ScaledMetric private var scaledSize: CGFloat
    @ScaledMetric private var scaledLine: CGFloat

    public init(_ style: MGTextStyle) {
        self.style = style
        _scaledSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
        _scaledLine = ScaledMetric(wrappedValue: style.lineHeight, relativeTo: style.relativeTo)
    }

    public func body(content: Content) -> some View {
        let size = min(scaledSize, style.size * style.maxScale)
        let line = min(scaledLine, style.lineHeight * style.maxScale)
        // SwiftUI cannot tighten lines below the font's own height; it can only add. 1.2 ≈ SF's natural leading.
        let extra = max(0, line - size * 1.2)
        return content
            .font(style.font(size: size))
            .tracking(style.trackingEm * size)
            .lineSpacing(extra)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension View {
    /// `Text("…").mgFont(.verdict)`
    public func mgFont(_ style: MGTextStyle) -> some View {
        modifier(MGTextStyleModifier(style))
    }
}
