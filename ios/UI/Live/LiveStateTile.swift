import SwiftUI
import MGContext
import MGDesign

// 0.6.0.12 (Mo, Nov 5 2026) — the two big live tiles (RMSSD 5 min, autonomic load) in their three looks: solid, GREY with the
// reason (a number that did not meet the window rules, or a stored value), blank (nothing streams). Pure rendering of
// `LiveTileState`; a tap runs `onTap` (the explainer card, added with the cards).
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

struct LiveStateTile: View {
    let label: String
    let tile: LiveTileState
    var caption: String? = nil
    var onTap: (() -> Void)? = nil
    /// Room under the text for the level meter drawn over the tile's bottom edge (autonomic load).
    var reserveMeter = false
    @Environment(\.mgColors) private var colors

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }.buttonStyle(MGPressButtonStyle())
        } else {
            content
        }
    }

    private var numberColor: Color {
        switch tile.kind {
        case .solid: return colors.ink.color
        case .grey, .blank: return colors.mute.color
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            Text(label).mgFont(.label).foregroundStyle(colors.ink2.color)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(tile.text)
                    .mgFont(.bigNumber)
                    .foregroundStyle(numberColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let unit = tile.unit, !unit.isEmpty {
                    Text(unit).mgFont(.unit).foregroundStyle(colors.mute.color)
                }
            }
            if let reason = tile.reason {
                Text(reason)
                    .mgFont(.detail)
                    .foregroundStyle(tile.kind == .grey ? colors.mute.color : colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = tile.note {
                Text(note)
                    .mgFont(.label)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                Text(caption)
                    .mgFont(.label)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MGSpace.tileInset)
        .padding(.bottom, reserveMeter ? 14 : 0)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .mgSurface(.tile)
        .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [label, tile.text + (tile.unit.map { " " + $0 } ?? "")]
        switch tile.kind {
        case .solid: break
        case .grey: parts.append("not fully reliable yet")
        case .blank: parts.append("no value")
        }
        if let r = tile.reason { parts.append(r) }
        if let n = tile.note { parts.append(n) }
        return parts.joined(separator: ", ")
    }
}
