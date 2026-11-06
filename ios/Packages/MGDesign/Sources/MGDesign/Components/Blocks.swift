import SwiftUI
import MGContext

// Small building blocks (ARCHITECTURE §4.8: Pill, Chip, SectionHeader, MGCard — MGCard lives in Surfaces.swift),
// plus SampleBanner and the research tag used by ValueView and MethodsStrip.

/// "SAMPLE DATA — NOT YOURS" stripe (BRIEF hard rule: shown on every screen while sample mode is on).
public struct SampleBanner: View {
    @Environment(\.mgColors) private var colors

    public init() {}

    public var body: some View {
        Text("Sample data — not yours")
            .mgFont(.kicker)
            .foregroundStyle(colors.sampleText.color)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background { SampleStripes(a: colors.sampleStripe1.color, b: colors.sampleStripe2.color) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample data. These numbers are not yours.")
            .accessibilityAddTraits(.isHeader)
    }
}

struct SampleStripes: View {
    let a: Color
    let b: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(a))
            // 135° stripes, 9 pt each (prototype `.sample`).
            let step: CGFloat = 18
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + 9, y: size.height))
                p.addLine(to: CGPoint(x: x + 9 + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.closeSubpath()
                ctx.fill(p, with: .color(b))
                x += step
            }
        }
    }
}

/// Dotted "research" tag (UX rule 4: research rows wear a dotted tag).
public struct ResearchTag: View {
    @Environment(\.mgColors) private var colors
    private let label: String

    public init(_ label: String = "research") {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .mgFont(.tag)
            .foregroundStyle(colors.ink2.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(colors.ink2.color, style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
            }
            .accessibilityLabel("research method")
    }
}

/// A meaning tag: mono 10, 1 pt outline, radius 6 ("est.", "raw", "decoded, untested"). One line, truncated in the middle.
public struct TagPill: View {
    @Environment(\.mgColors) private var colors
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .mgFont(.tag)
            .foregroundStyle(colors.ink2.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: MGRadius.tag, style: .continuous)
                    .strokeBorder(colors.ink2.color, lineWidth: 1)
            }
    }
}

/// Button weight (0.6): weight follows frequency. `filled` = the primary labelled action, `tonal` = a quiet
/// action (chip fill), `outline` = a secondary one (1 pt rule border).
public enum MGButtonWeight: Sendable {
    case filled, tonal, outline
}

/// The 44 pt capsule shared by `Pill` and `MGButton`.
private struct WeightedCapsule<Label: View>: View {
    @Environment(\.mgColors) private var colors
    let weight: MGButtonWeight
    let horizontalPadding: CGFloat
    let label: Label

    var body: some View {
        label
            .mgFont(.button)
            .foregroundStyle(weight == .filled ? colors.buttonText.color : colors.ink.color)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: MGSpace.tapTarget)
            .background {
                switch weight {
                case .filled: Capsule().fill(colors.buttonFill.color)
                case .tonal: Capsule().fill(colors.chip.color)
                case .outline: Capsule().strokeBorder(colors.rule.color, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }
}

/// A rounded button-like capsule (quick-log pills, "More ›").
public struct Pill: View {
    private let title: String
    private let systemImage: String?
    private let weight: MGButtonWeight
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, weight: MGButtonWeight, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.weight = weight
        self.action = action
    }

    /// `prominent` = `.filled` (e.g. the "1 to confirm" chip); otherwise `.tonal`.
    public init(_ title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, weight: prominent ? .filled : .tonal, action: action)
    }

    public var body: some View {
        Button(action: action) {
            WeightedCapsule(weight: weight, horizontalPadding: 14, label: HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true) }
                Text(title)
            })
        }
        .buttonStyle(MGPressButtonStyle())
    }
}

/// A small selectable chip (answer chips, type / place chips).
public struct Chip: View {
    @Environment(\.mgColors) private var colors
    private let title: String
    private let selected: Bool
    private let action: () -> Void

    public init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .mgFont(.detail)
                .foregroundStyle(selected ? colors.buttonText.color : colors.ink.color)
                .padding(.horizontal, 12)
                .frame(minHeight: MGSpace.tapTarget)
                .background {
                    RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                        .fill(selected ? colors.buttonFill.color : colors.chip.color)
                }
                .contentShape(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous))
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An action button (moment card actions, peek primary answer).
public struct MGButton: View {
    /// `ghost` is the old name of `outline`.
    public enum Style: Sendable { case filled, ghost }
    private let title: String
    private let weight: MGButtonWeight
    private let action: () -> Void

    public init(_ title: String, weight: MGButtonWeight, action: @escaping () -> Void) {
        self.title = title
        self.weight = weight
        self.action = action
    }

    public init(_ title: String, style: Style = .filled, action: @escaping () -> Void) {
        self.init(title, weight: style == .filled ? .filled : .outline, action: action)
    }

    public var body: some View {
        Button(action: action) {
            WeightedCapsule(weight: weight, horizontalPadding: 16, label: Text(title))
        }
        .buttonStyle(MGPressButtonStyle())
    }
}

/// Section head: serif title left, a small ink2 note right (prototype `.sech`).
public struct SectionHeader: View {
    @Environment(\.mgColors) private var colors
    private let title: String
    private let note: String?

    public init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer(minLength: 8)
                noteText
            }
            VStack(alignment: .leading, spacing: 2) {
                titleText
                noteText
            }
        }
        .padding(.top, MGSpace.section - 2)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleText: some View {
        Text(title).mgFont(.headline).foregroundStyle(colors.ink.color)
    }

    @ViewBuilder private var noteText: some View {
        if let note {
            Text(note).mgFont(.detail).foregroundStyle(colors.ink2.color)
        }
    }
}

/// A 40 pt round letter badge on a 15 % wash of its accent (Now rows). The letter uses the accent's TEXT colour.
public struct LetterBadge: View {
    @Environment(\.mgColors) private var colors
    private let letter: String
    private let accent: InkTone

    public init(_ letter: String, accent: InkTone) {
        self.letter = letter
        self.accent = accent
    }

    public var body: some View {
        Text(letter)
            .mgFont(MGTextStyle(family: .serif, size: 17, lineHeight: 20, weight: .semibold,
                                relativeTo: .headline, maxScale: 1.4))
            .foregroundStyle(colors.text(accent).color)
            .frame(width: 40, height: 40)
            .background(Circle().fill(colors.mark(accent).opacity(0.15).color))
            .accessibilityHidden(true)
    }
}
