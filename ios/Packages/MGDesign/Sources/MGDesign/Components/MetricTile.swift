import SwiftUI
import MGContext

/// A label, a value and an optional caption on the tile surface (0.6). The meaning tag stays next to the value
/// (`ValueView`); a blank shows "—" and its reason, never a number. Pass `onTap` to make the whole tile a button.
public struct MetricTile: View {
    public enum Size: Sendable { case large, small }

    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let label: String
    private let value: DisplayValue
    private let caption: String?
    private let size: Size
    private let onTap: (() -> Void)?

    public init(label: String, value: DisplayValue, caption: String? = nil, size: Size = .large,
                onTap: (() -> Void)? = nil) {
        self.label = label
        self.value = value
        self.caption = caption
        self.size = size
        self.onTap = onTap
    }

    public var body: some View {
        if let onTap {
            Button(action: onTap) { tile }.buttonStyle(MGPressButtonStyle())
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            Text(label).mgFont(.label).foregroundStyle(colors.ink2.color)
            ValueView(value, size: size == .large ? .big : .number)
                .contentTransition(.numericText())
                .animation(MGMotion.numeric(reduceMotion: reduceMotion), value: value)
            if let caption {
                Text(caption)
                    .mgFont(.label)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MGSpace.tileInset)
        .frame(maxWidth: .infinity, minHeight: size == .large ? 88 : 72, alignment: .topLeading)
        .mgSurface(.tile)
        .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
