import SwiftUI
import MGContext

// Colour tokens for the four themes — UX-SPEC §1.2, with the extra tokens the prototype CSS defines
// (app/prototype/index.html lines 41-44: --trackP, --trackD, --chip, --peek, --sheet, --bodyW, --sleepW, --muteW).
//
// FORMAT RULE: `Tools/check_contrast.py` parses this file as text. Keep one `token: value,` per line inside each
// `public static let <name> = ThemeColors(` block, colours only as `.hex(0xRRGGBB)`, `.hex(0xRRGGBB, alpha: a)`
// or `.rgba(r, g, b, a)`, and close each block with `    )` on its own line. Run the checker after any change:
//     python app/ios/Packages/MGDesign/Tools/check_contrast.py
//
// CONTRAST CHANGES against UX-SPEC §1.2 (WP-07, 2026-10-11 02:26 PT). The spec's own note says the top ~200 pt of
// the Emerald gradient is lighter. Measured here: with the spec values, secondary text fails 4.5:1 there, and
// Emerald-low `mute` fails everywhere (3.99:1 at best). Fixes, each re-checked by the script:
//   1. The emerald background scrolls WITH the content (MGScreen), so the bright glow only ever sits behind the
//      header. Secondary text (ink2, mute, accent text) is checked from content y = 140 pt down; header text uses
//      `topText`, checked from y = 47 pt.
//   2. Worst case = content y 140 on a 932 pt screen (the brightest point body text can reach):
//      Emerald `ink2`     was rgba(214,236,224,.74) → now .80 (was 4.44:1; also keeps a step above the raised mute)
//      Emerald `mute`     was rgba(214,236,224,.66) → now .76 (was 3.87:1)
//      Emerald-low `ink2` was rgba(196,220,206,.64) → now .74 (was 4.22:1)
//      Emerald-low `mute` was rgba(196,220,206,.50) → now .68 (was 3.17:1; 3.99:1 even at the darkest point)
//   3. New `*Text` tokens: the accent colour to use when an accent is TEXT (callout values, badge letters,
//      moment-card kickers). Marks (arcs, dots, bands) keep the UX accent. Cream `focus` (3.55:1) and `caffeine`
//      (3.17:1) fail as text on paper; on emerald every accent fails somewhere in the 140-200 pt band.
//   Cream / golden ink, ink2, mute pass as specified (golden mute #5D6861 already darkened in the spec).
//
// 0.6 "Sundial rings" (P00 / T9500, 2026-10-13 PT). Values now come from ui-pitch/DESIGN-TOKENS.md §1, not UX-SPEC §1.2:
//   Day paper is warmer and softer (#F3EEE3 / golden #F3EADB), Day cards get a 1 pt border, Night backgrounds are the
//   darker, calmer green of the 0.5.3 screenshots, Night glass is a little darker and its pale-mint button is brighter.
//   New tokens: `stress` / `stressText` (4th ring), `well` (recessed disc), `ringTrack` (unfilled ring part).
//   Day `mute` #626D66 -> #5F6A63 and Day `rule` -> #E0D8C8 follow the new paper. The four notes above still hold: the
//   Night ink2 / mute values keep their raised alphas, so no 0.5.x contrast fix is undone. Why: the redesign asks for a
//   finished look without touching the contrast guarantees; `check_contrast.py` now checks `stressText` too.
//   One departure from DESIGN-TOKENS: Day-golden `stressText` #2A6390 -> #276090 (was 4.42:1 on a 15 % stress wash,
//   needs 4.5:1; now 4.60:1).

/// How a theme paints the screen behind everything.
public enum ThemeBackground: Hashable, Sendable {
    case solid(MGRGBA)
    /// CSS `radial-gradient(<radiusX*100>% <radiusY*100>% at <centerX*100>% <centerY*100>%, stops…)`:
    /// an ellipse whose radii are fractions of the screen width and height, centred at a unit point.
    case radial(stops: [GradientStopToken], centerX: Double, centerY: Double, radiusX: Double, radiusY: Double)

    /// The colour at the far edge (what shows below a long scroll and in bottom overscroll).
    public var lastColor: MGRGBA {
        switch self {
        case .solid(let c): return c
        case .radial(let stops, _, _, _, _): return stops.last?.color ?? .hex(0x000000)
        }
    }

    /// The colour at the top edge of the screen (what shows in top overscroll).
    public var firstColor: MGRGBA {
        switch self {
        case .solid(let c): return c
        case .radial(let stops, _, _, _, _): return stops.first?.color ?? .hex(0x000000)
        }
    }
}

public struct GradientStopToken: Hashable, Sendable {
    public let color: MGRGBA
    public let location: Double
    public init(_ color: MGRGBA, _ location: Double) {
        self.color = color
        self.location = location
    }
}

/// How cards, the moment card and chips fill their shape.
public enum SurfaceStyle: Hashable, Sendable {
    case solid(MGRGBA, border: MGRGBA?)
    /// Satin Emerald glass: a backdrop blur, a dark tint, a white top-to-bottom highlight and a 1 pt border.
    case glass(tint: MGRGBA, highlightTop: Double, highlightBottom: Double, border: MGRGBA, blur: Double)
}

/// Every colour token of one theme. Build views from these, never from literals.
public struct ThemeColors: Hashable, Sendable {
    public let isDark: Bool
    public let background: ThemeBackground
    /// Cards, moment card, status chip.
    public let surface: SurfaceStyle
    /// The peek (one-question card) fill.
    public let peek: MGRGBA
    /// Sheet fill (Tonight, Strap & sync) and the opaque glass fallback under Reduce Transparency.
    public let sheet: MGRGBA
    /// Answer buttons, chips, segmented controls.
    public let chip: MGRGBA

    public let ink: MGRGBA
    public let ink2: MGRGBA
    /// Receipts, axes, captions.
    public let mute: MGRGBA
    /// Secondary text inside the header / top glow (the top ~140 pt). Cream: ink2. Emerald: ink (contrast).
    public let topText: MGRGBA
    /// Hairlines.
    public let rule: MGRGBA
    public let buttonFill: MGRGBA
    public let buttonText: MGRGBA

    // Accents for marks (arcs, dots, bands, badges' tint).
    public let sleep: MGRGBA
    public let focus: MGRGBA
    public let caffeine: MGRGBA
    /// Vape, workout, heart, alerts.
    public let body: MGRGBA
    /// Pulse trace.
    public let live: MGRGBA
    /// Stress ring and marks (0.6).
    public let stress: MGRGBA

    // The same accents when they are TEXT (≥ 4.5:1 on bg, surface and peek — see header note 3).
    public let sleepText: MGRGBA
    public let focusText: MGRGBA
    public let caffeineText: MGRGBA
    public let bodyText: MGRGBA
    public let liveText: MGRGBA
    public let stressText: MGRGBA

    // Vernier three-band strip.
    public let bandLow: MGRGBA
    public let bandMid: MGRGBA
    public let bandHigh: MGRGBA

    // Sleep stages.
    public let stageDeep: MGRGBA
    public let stageLight: MGRGBA
    public let stageRem: MGRGBA
    public let stageAwake: MGRGBA

    // Dial track and hatch washes (prototype CSS).
    public let trackPale: MGRGBA
    public let trackDone: MGRGBA
    public let bodyWash: MGRGBA
    public let sleepWash: MGRGBA
    public let muteWash: MGRGBA
    /// The recessed disc behind the inner rings (0.6).
    public let well: MGRGBA
    /// The unfilled part of an inner ring (0.6).
    public let ringTrack: MGRGBA

    // SAMPLE banner.
    public let sampleStripe1: MGRGBA
    public let sampleStripe2: MGRGBA
    public let sampleText: MGRGBA

    /// Drop shadow under the moment card and the peek.
    public let shadow: MGRGBA
}

/// The one place a theme name becomes colours (ARCHITECTURE §4.8: `Theme.colors(for: ThemeName)`).
public enum Theme {
    public static func colors(for name: ThemeName) -> ThemeColors {
        switch name {
        case .cream: return .cream
        case .creamGolden: return .creamGolden
        case .emerald: return .emerald
        case .emeraldLow: return .emeraldLow
        }
    }
}

extension ThemeColors {
    /// The mark colour of a semantic ink (MGContext `InkTone`): arcs, dots, bands, badge washes.
    public func mark(_ tone: InkTone) -> MGRGBA {
        switch tone {
        case .ink: return ink
        case .ink2: return ink2
        case .mute: return mute
        case .sleep: return sleep
        case .focus: return focus
        case .caffeine: return caffeine
        case .body: return body
        case .live: return live
        }
    }

    /// The same ink when it is TEXT (callout values, badge letters, kickers): ≥ 4.5:1 (header note 3).
    public func text(_ tone: InkTone) -> MGRGBA {
        switch tone {
        case .ink: return ink
        case .ink2: return ink2
        case .mute: return mute
        case .sleep: return sleepText
        case .focus: return focusText
        case .caffeine: return caffeineText
        case .body: return bodyText
        case .live: return liveText
        }
    }

    /// The mark colour of an inner dial ring (DESIGN-TOKENS §1). Not an `InkTone` case: that enum is matched
    /// exhaustively all over the app. Burned and eaten both use ink2; eaten is drawn dashed by the view.
    public func ring(_ kind: DialRing.Kind) -> MGRGBA {
        switch kind {
        case .strain: return body
        case .recovery: return focus
        case .sleep: return sleep
        case .stress: return stress
        case .burn, .eaten: return ink2
        }
    }

    /// The same ring colour when it is TEXT (ring chips, callouts).
    public func ringText(_ kind: DialRing.Kind) -> MGRGBA {
        switch kind {
        case .strain: return bodyText
        case .recovery: return focusText
        case .sleep: return sleepText
        case .stress: return stressText
        case .burn, .eaten: return ink2
        }
    }

    /// Status dots: good = focus (green), warn = caffeine (amber), bad = body (red), neutral = mute (grey).
    public func status(_ tone: StatusTone) -> MGRGBA {
        switch tone {
        case .good: return focus
        case .warn: return caffeine
        case .bad: return body
        case .neutral: return mute
        }
    }
}

// MARK: - The four palettes

extension ThemeColors {
    /// Day — morning to late afternoon (warm paper, hairline-bordered cards, ink, four earth inks).
    public static let cream = ThemeColors(
        isDark: false,
        background: .solid(.hex(0xF3EEE3)),
        surface: .solid(.hex(0xFBF8F1), border: .hex(0xE6DFD0)),
        peek: .hex(0xFDFBF6),
        sheet: .hex(0xF8F4EA),
        chip: .hex(0xEAE3D4),
        ink: .hex(0x1C2922),
        ink2: .hex(0x4C5A52),
        mute: .hex(0x5F6A63),
        topText: .hex(0x4C5A52),
        rule: .hex(0xE0D8C8),
        buttonFill: .hex(0x1C2922),
        buttonText: .hex(0xFBF8F1),
        sleep: .hex(0x3A4FA6),
        focus: .hex(0x4F8A3E),
        caffeine: .hex(0xB07A0E),
        body: .hex(0xB8433F),
        live: .hex(0xB8433F),
        stress: .hex(0x2F6E9E),
        sleepText: .hex(0x3A4FA6),
        focusText: .hex(0x3C692F),
        caffeineText: .hex(0x80580A),
        bodyText: .hex(0xA03A37),
        liveText: .hex(0xA03A37),
        stressText: .hex(0x2A6390),
        bandLow: .hex(0xF0D6CA),
        bandMid: .hex(0xF1E2C0),
        bandHigh: .hex(0xD8E5CD),
        stageDeep: .hex(0x26357A),
        stageLight: .hex(0x5D6FB0),
        stageRem: .hex(0x98A5D6),
        stageAwake: .hex(0xD9D4C4),
        trackPale: .hex(0xE8E1D2),
        trackDone: .hex(0xD7CEBB),
        bodyWash: .hex(0xF2DDD2),
        sleepWash: .hex(0xDDE0F0),
        muteWash: .hex(0xE8E1D2),
        well: .hex(0xEDE6D8),
        ringTrack: .hex(0xE1D9C9),
        sampleStripe1: .hex(0x1C2922),
        sampleStripe2: .hex(0x2A3A31),
        sampleText: .hex(0xF8F7F1),
        shadow: .rgba(40, 45, 35, 0.18)
    )

    /// Day, golden — the last 60 min of late afternoon. Paper warms; same inks.
    public static let creamGolden = ThemeColors(
        isDark: false,
        background: .solid(.hex(0xF3EADB)),
        surface: .solid(.hex(0xFBF5EA), border: .hex(0xE8DCC6)),
        peek: .hex(0xFDF8EF),
        sheet: .hex(0xF8F0E2),
        chip: .hex(0xEBE0CB),
        ink: .hex(0x1C2922),
        ink2: .hex(0x4C5A52),
        mute: .hex(0x5D6861),
        topText: .hex(0x4C5A52),
        rule: .hex(0xDDD3BF),
        buttonFill: .hex(0x1C2922),
        buttonText: .hex(0xFBF5EA),
        sleep: .hex(0x3A4FA6),
        focus: .hex(0x4F8A3E),
        caffeine: .hex(0xB07A0E),
        body: .hex(0xB8433F),
        live: .hex(0xB8433F),
        stress: .hex(0x2F6E9E),
        sleepText: .hex(0x3A4FA6),
        focusText: .hex(0x3C692F),
        caffeineText: .hex(0x80580A),
        bodyText: .hex(0xA03A37),
        liveText: .hex(0xA03A37),
        stressText: .hex(0x276090),
        bandLow: .hex(0xF0D6CA),
        bandMid: .hex(0xF1E2C0),
        bandHigh: .hex(0xD8E5CD),
        stageDeep: .hex(0x26357A),
        stageLight: .hex(0x5D6FB0),
        stageRem: .hex(0x98A5D6),
        stageAwake: .hex(0xD9D4C4),
        trackPale: .hex(0xE9DFCB),
        trackDone: .hex(0xDACEB6),
        bodyWash: .hex(0xF2DDD2),
        sleepWash: .hex(0xDDE0F0),
        muteWash: .hex(0xE9DFCB),
        well: .hex(0xEFE5D3),
        ringTrack: .hex(0xE3D7C0),
        sampleStripe1: .hex(0x1C2922),
        sampleStripe2: .hex(0x2A3A31),
        sampleText: .hex(0xF8F7F1),
        shadow: .rgba(40, 45, 35, 0.18)
    )

    /// Night — sundown and night. Dark green radial, glass cards, pale mint.
    public static let emerald = ThemeColors(
        isDark: true,
        background: .radial(stops: [
            GradientStopToken(.hex(0x16573F), 0.00),
            GradientStopToken(.hex(0x0C3E2C), 0.32),
            GradientStopToken(.hex(0x072B1F), 0.64),
            GradientStopToken(.hex(0x04190F), 1.00),
        ], centerX: 0.5, centerY: -0.10, radiusX: 1.20, radiusY: 0.70),
        surface: .glass(tint: .rgba(2, 22, 15, 0.44), highlightTop: 0.05, highlightBottom: 0.015,
                        border: .rgba(214, 255, 236, 0.11), blur: 22),
        peek: .rgba(5, 40, 28, 0.95),
        sheet: .hex(0x072D20),
        chip: .rgba(255, 255, 255, 0.08),
        ink: .hex(0xF2F6F1),
        ink2: .rgba(214, 236, 224, 0.80),
        mute: .rgba(214, 236, 224, 0.76),
        topText: .hex(0xF2F6F1),
        rule: .rgba(214, 255, 236, 0.12),
        buttonFill: .hex(0xE3EFE8),
        buttonText: .hex(0x053222),
        sleep: .hex(0xB4A0F0),
        focus: .hex(0x7FD6A6),
        caffeine: .hex(0xF2BE6A),
        body: .hex(0xF2879F),
        live: .hex(0x8FD4FF),
        stress: .hex(0x7CC4EE),
        sleepText: .hex(0xD5CAF6),
        focusText: .hex(0xABE5C5),
        caffeineText: .hex(0xF5D092),
        bodyText: .hex(0xF7BCC9),
        liveText: .hex(0xAFE0FF),
        stressText: .hex(0xB2DCF6),
        bandLow: .rgba(242, 135, 159, 0.28),
        bandMid: .rgba(242, 190, 106, 0.28),
        bandHigh: .rgba(127, 214, 166, 0.28),
        stageDeep: .hex(0x8E76E0),
        stageLight: .hex(0xB4A0F0),
        stageRem: .hex(0xDCCFFB),
        stageAwake: .rgba(255, 255, 255, 0.16),
        trackPale: .rgba(255, 255, 255, 0.08),
        trackDone: .rgba(255, 255, 255, 0.16),
        bodyWash: .rgba(242, 135, 159, 0.22),
        sleepWash: .rgba(180, 160, 240, 0.18),
        muteWash: .rgba(255, 255, 255, 0.08),
        well: .rgba(0, 0, 0, 0.22),
        ringTrack: .rgba(255, 255, 255, 0.07),
        sampleStripe1: .hex(0xF2BE6A),
        sampleStripe2: .hex(0xE0AC57),
        sampleText: .hex(0x032418),
        shadow: .rgba(0, 0, 0, 0.45)
    )

    /// Night low — late night. Darker radial, no glow highlight on glass, dimmer text.
    /// Stages are the emerald stages ×0.85 (UX §1.2), as the prototype CSS spells them out.
    public static let emeraldLow = ThemeColors(
        isDark: true,
        background: .radial(stops: [
            GradientStopToken(.hex(0x0C3E2C), 0.00),
            GradientStopToken(.hex(0x072B1F), 0.40),
            GradientStopToken(.hex(0x04190F), 0.78),
            GradientStopToken(.hex(0x02100A), 1.00),
        ], centerX: 0.5, centerY: -0.10, radiusX: 1.20, radiusY: 0.70),
        surface: .glass(tint: .rgba(2, 18, 12, 0.56), highlightTop: 0.0, highlightBottom: 0.0,
                        border: .rgba(214, 255, 236, 0.08), blur: 22),
        peek: .rgba(3, 28, 19, 0.96),
        sheet: .hex(0x052419),
        chip: .rgba(255, 255, 255, 0.08),
        ink: .hex(0xD5E2DA),
        ink2: .rgba(196, 220, 206, 0.74),
        mute: .rgba(196, 220, 206, 0.68),
        topText: .hex(0xD5E2DA),
        rule: .rgba(214, 255, 236, 0.08),
        buttonFill: .hex(0xCFE0D6),
        buttonText: .hex(0x032418),
        sleep: .hex(0x9C8AD6),
        focus: .hex(0x6BB58E),
        caffeine: .hex(0xD7A85D),
        body: .hex(0xD47A8E),
        live: .hex(0x7DB8DD),
        stress: .hex(0x6FAACF),
        sleepText: .hex(0xB7AAE1),
        focusText: .hex(0x88C4A4),
        caffeineText: .hex(0xDAAF69),
        bodyText: .hex(0xDF9DAC),
        liveText: .hex(0x8AC0E0),
        stressText: .hex(0x98C3DE),
        bandLow: .rgba(212, 122, 142, 0.20),
        bandMid: .rgba(215, 168, 93, 0.20),
        bandHigh: .rgba(107, 181, 142, 0.20),
        stageDeep: .hex(0x7965C0),
        stageLight: .hex(0x9C8AD6),
        stageRem: .hex(0xBEB1E6),
        stageAwake: .rgba(255, 255, 255, 0.14),
        trackPale: .rgba(255, 255, 255, 0.08),
        trackDone: .rgba(255, 255, 255, 0.16),
        bodyWash: .rgba(212, 122, 142, 0.20),
        sleepWash: .rgba(156, 138, 214, 0.16),
        muteWash: .rgba(255, 255, 255, 0.08),
        well: .rgba(0, 0, 0, 0.26),
        ringTrack: .rgba(255, 255, 255, 0.06),
        sampleStripe1: .hex(0xF2BE6A),
        sampleStripe2: .hex(0xE0AC57),
        sampleText: .hex(0x032418),
        shadow: .rgba(0, 0, 0, 0.50)
    )
}
