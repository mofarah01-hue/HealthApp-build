import SwiftUI

// WP-27 — the widget look: cream by day, Satin Emerald from sundown (BRIEF design inputs; UX-SPEC §1.2).
//
// These are the SAME values as MGDesign's ThemeColors (Packages/MGDesign/Sources/MGDesign/Tokens/ThemeColors.swift,
// WP-07, contrast-checked there), copied as plain numbers because the widget extension links MGDomain only, not
// MGDesign / MGContext (a widget has a small memory budget and does not need the design system's charts and components).
// If a token changes there, change it here: the names below are the MGDesign names.

struct QuickLogPalette {
    /// Background stops, first = top. One entry = a flat colour.
    let background: [Color]
    let isRadial: Bool
    /// MGDesign `chip`: button tiles.
    let chip: Color
    let ink: Color
    let ink2: Color
    /// MGDesign `bodyText` (vape, heart, alerts).
    let vape: Color
    /// MGDesign `focusText`.
    let med: Color
    /// MGDesign `caffeineText`.
    let drink: Color

    static func make(_ theme: QuickLogTheme) -> QuickLogPalette {
        switch theme {
        case .cream:
            return QuickLogPalette(
                background: [Color(qlHex: 0xEFEDE3)], isRadial: false, chip: Color(qlHex: 0xE4E1D5),
                ink: Color(qlHex: 0x1C2922), ink2: Color(qlHex: 0x4C5A52),
                vape: Color(qlHex: 0xA03A37), med: Color(qlHex: 0x3C692F), drink: Color(qlHex: 0x80580A))
        case .creamGolden:
            return QuickLogPalette(
                background: [Color(qlHex: 0xF1E9D9)], isRadial: false, chip: Color(qlHex: 0xE9DFCB),
                ink: Color(qlHex: 0x1C2922), ink2: Color(qlHex: 0x4C5A52),
                vape: Color(qlHex: 0xA03A37), med: Color(qlHex: 0x3C692F), drink: Color(qlHex: 0x80580A))
        case .emerald:
            return QuickLogPalette(
                background: [Color(qlHex: 0x1E9466), Color(qlHex: 0x0B5E43), Color(qlHex: 0x064230), Color(qlHex: 0x032418)],
                isRadial: true, chip: Color(qlHex: 0xFFFFFF, opacity: 0.09),
                ink: Color(qlHex: 0xF2F6F1), ink2: Color(qlHex: 0xD6ECE0, opacity: 0.80),
                vape: Color(qlHex: 0xF7BCC9), med: Color(qlHex: 0xABE5C5), drink: Color(qlHex: 0xF5D092))
        case .emeraldLow:
            return QuickLogPalette(
                background: [Color(qlHex: 0x0B5E43), Color(qlHex: 0x064230), Color(qlHex: 0x032418), Color(qlHex: 0x021A11)],
                isRadial: true, chip: Color(qlHex: 0xFFFFFF, opacity: 0.09),
                ink: Color(qlHex: 0xD5E2DA), ink2: Color(qlHex: 0xC4DCCE, opacity: 0.74),
                vape: Color(qlHex: 0xDF9DAC), med: Color(qlHex: 0x88C4A4), drink: Color(qlHex: 0xDAAF69))
        }
    }
}

extension Color {
    /// sRGB from 0xRRGGBB.
    init(qlHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The widget's container background (`containerBackground(for: .widget)`).
struct QuickLogBackground: View {
    let theme: QuickLogTheme

    var body: some View {
        let p = QuickLogPalette.make(theme)
        if p.isRadial {
            // MGDesign: radial from the top centre (centre y −0.14, radius ≈ 1.2 × width / 0.72 × height).
            RadialGradient(colors: p.background, center: UnitPoint(x: 0.5, y: -0.14), startRadius: 0, endRadius: 200)
        } else {
            p.background[0]
        }
    }
}
