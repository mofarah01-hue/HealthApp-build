#if DEBUG
import SwiftUI
import MGContext
import MGDomain

// Design-system sheet: every theme's tokens and the ValueView marks (blank + reason, measured underline,
// ± estimate, research tag, raw strap count), the methods strip, a moment card and a peek — SAMPLE values only.

struct DesignSheet: View {
    let theme: ThemeName

    private static let at = SampleDay.at(6, 58)
    private static let values: [(String, DisplayValue)] = [
        ("plain", .value(text: "52", unit: "ms", receipt: Receipt(computedOn: .phone, tier: .high, at: at),
                         style: .plain, sample: true)),
        ("measured", .value(text: "121/78", unit: "mmHg", receipt: Receipt(computedOn: .phone, tier: .verified, at: at),
                            style: .measured, sample: true)),
        ("estimate", .value(text: "14.8", unit: "/min", receipt: Receipt(computedOn: .phone, tier: .estimate, at: at),
                            style: .estimate(Uncertainty(sd: 1.1)), sample: true)),
        ("research", .value(text: "51", unit: "/100", receipt: Receipt(computedOn: .pc, tier: .research, at: at),
                            style: .research, sample: true)),
        ("strap raw", .value(text: "96", unit: "%", receipt: Receipt(computedOn: .strap, tier: .strap, at: at),
                             style: .strapRaw, sample: true)),
        ("blank", .blank(reason: "38 % of beats were noisy; nothing reliable.",
                         receipt: Receipt(computedOn: .phone, tier: .high, at: at))),
    ]

    /// 0.6 shared pieces: pill weights, tag, metric tiles, ring gauges, status chip, compact moment card.
    @ViewBuilder private var newPieces: some View {
        let c = Theme.colors(for: theme)
        let ok = DesignSheet.values[0].1
        HStack {
            Pill("Filled", weight: .filled) {}
            Pill("Tonal", weight: .tonal) {}
            Pill("Outline", weight: .outline) {}
        }
        HStack { TagPill(text: "raw"); TagPill(text: "decoded, untested"); ResearchTag() }
        HStack(alignment: .top) {
            MetricTile(label: "Resting HR", value: ok, caption: "Lower than your usual.", size: .large) {}
            MetricTile(label: "HRV", value: ok, size: .small)
        }
        MetricTile(label: "SpO2", value: DesignSheet.values[5].1, size: .small)
        HStack(spacing: 16) {
            RingGauge(fraction: 0, color: c.ring(.strain).color, track: c.ringTrack.color, lineWidth: 8)
            RingGauge(fraction: 0.6, target: 0.67...0.86, color: c.ring(.recovery).color, track: c.ringTrack.color,
                      lineWidth: 8)
            RingGauge(fraction: nil, color: c.ring(.sleep).color, track: c.ringTrack.color, lineWidth: 8)
            RingGauge(fraction: 0.4, color: c.ring(.eaten).color, track: c.ringTrack.color, lineWidth: 8, dashed: true)
        }
        .frame(height: 76)
        .padding(10)
        .background(c.well.color, in: RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        HStack(spacing: 10) {
            ConcentricRingsIcon(count: 4, highlighted: 1, colors: [c.ring(.strain).color, c.ring(.recovery).color,
                                                                  c.ring(.sleep).color, c.ring(.stress).color])
            StatusChip(state: StatusChipState(strapTone: .good, strapText: "MG 79 %", syncTone: .warn,
                                              syncText: "Synced 9:24 PM")) { print($0) }
        }
        MomentCard(moment: MomentViewState(kind: .historyDownloading, title: "Catching up", trailing: "62%",
                                           line: "Downloading last night from the strap.", detail: nil, actionTitle: nil,
                                           action: nil, progress: 0.62, tone: .sleep, extraCount: 0)) { print($0) }
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(theme.rawValue)").mgFont(.kicker).foregroundStyle(Theme.colors(for: theme).topText.color)
                Text("Recovered, mostly.").mgFont(.verdict).foregroundStyle(Theme.colors(for: theme).ink.color)
                Text("In your focus window until 12:00. A coffee is fine until 10:24.")
                    .mgFont(.body).foregroundStyle(Theme.colors(for: theme).ink2.color)
                ForEach(Array(DesignSheet.values.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top) {
                        Text(pair.0).mgFont(.receipt).foregroundStyle(Theme.colors(for: theme).mute.color)
                            .frame(width: 70, alignment: .leading)
                        ValueView(pair.1, size: .number, showsReceipt: true)
                    }
                }
                MethodsStrip(state: .preview) { print($0) }
                MomentCard(moment: MomentViewState(kind: .strapOff, title: "Strap off · since 15:12", trailing: "28 min",
                                                   line: "Nothing records while it's off.", detail: nil,
                                                   actionTitle: "Remind me in 30 min", action: .remindStrapOff(minutes: 30),
                                                   tone: .body, extraCount: 1)) { print($0) }
                PeekCard(state: .previewWearLocation) { print($0) }
                HStack {
                    ForEach([InkTone.sleep, .focus, .caffeine, .body, .live], id: \.self) { tone in
                        LetterBadge(String(tone.rawValue.prefix(1)).uppercased(), accent: tone)
                    }
                }
                newPieces
            }
            .padding(.vertical, 20)
        }
        .safeAreaInset(edge: .top, spacing: 0) { SampleBanner() }
        .mgTheme(theme)
    }
}

#Preview("Cream") { DesignSheet(theme: .cream) }
#Preview("Cream, golden") { DesignSheet(theme: .creamGolden) }
#Preview("Satin Emerald") { DesignSheet(theme: .emerald) }
#Preview("Emerald low") { DesignSheet(theme: .emeraldLow) }
#endif
