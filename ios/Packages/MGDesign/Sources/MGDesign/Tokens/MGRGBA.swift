import SwiftUI

/// One colour as plain numbers: sRGB channels 0–255 and alpha 0–1.
///
/// Tokens are stored as numbers, not `Color`, so `Tools/check_contrast.py` can read the exact shipped values
/// straight from `ThemeColors.swift` and compute WCAG contrast without a Swift toolchain.
public struct MGRGBA: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `.hex(0x1C2922)` — opaque unless `alpha` is given.
    public static func hex(_ value: UInt32, alpha: Double = 1) -> MGRGBA {
        MGRGBA(red: Double((value >> 16) & 0xFF),
               green: Double((value >> 8) & 0xFF),
               blue: Double(value & 0xFF),
               alpha: alpha)
    }

    /// `.rgba(214, 236, 224, 0.74)` — the CSS `rgba()` form used in UX-SPEC §1.2.
    public static func rgba(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> MGRGBA {
        MGRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var color: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }

    /// Same colour, alpha multiplied by `factor` (used for "at 28 %" style tokens and pale/predicted marks).
    public func opacity(_ factor: Double) -> MGRGBA {
        MGRGBA(red: red, green: green, blue: blue, alpha: alpha * factor)
    }
}
