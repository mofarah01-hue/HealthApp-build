import SwiftUI

/// Calm placeholder for a screen whose state has not arrived yet (first launch, a slow load): a header, a dial-sized disc and
/// three rows in `trackPale`, pulsing slowly (a still 0.7 under Reduce Motion). Replaces a bare spinner.
public struct LoadingBlock: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.xl) {
            RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                .frame(width: 200, height: 34)
            Circle()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 344)
                .frame(maxWidth: .infinity)
            VStack(spacing: MGSpace.m) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous)
                        .frame(height: MGSpace.rowMinHeight)
                }
            }
        }
        .foregroundStyle(colors.trackPale.color)
        .padding(.top, MGSpace.l)
        .opacity(reduceMotion ? 0.7 : (bright ? 0.85 : 0.55))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: bright)
        .onAppear { bright = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

#if DEBUG
#Preview("Loading, Day") { MGScreen { LoadingBlock() }.mgTheme(.cream) }
#Preview("Loading, Night") { MGScreen { LoadingBlock() }.mgTheme(.emerald) }
#endif
