import SwiftUI
import MGContext
import MGDesign

// The two info cards the Sundial shows for a finger (round 8, T10023): the ring's card (stepping from ring to ring, or
// the selected ring in magnify) and the time card (the day's numbers at the scrubbed time, each with its source word,
// or a reason when blank). Plain views of values the state already holds: no maths, no presenter work per move.

/// The ring's info, from the same `DialDetail` the sheet is built from (kicker, title, value, first 3 rows).
struct SundialRingCard: View {
    let state: DialState
    let kind: DialRing.Kind

    @Environment(\.mgColors) private var colors

    var body: some View {
        let detail = state.details.first { $0.id == .ring(kind) }
        let ring = state.rings.first { $0.kind == kind }
        VStack(alignment: .leading, spacing: 4) {
            Text(detail?.kicker ?? ring?.title ?? "")
                .mgFont(.kicker)
                .foregroundStyle(colors.ringText(kind).color)
            Text(detail?.title ?? ring?.title ?? "")
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
                .lineLimit(2)
            if let value = detail?.value ?? ring?.value { ValueView(value, size: .small) }
            ForEach(Array((detail?.rows ?? []).prefix(3)), id: \.id) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ValueView(row.value, size: .small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.card, radius: MGRadius.chip, shadow: true)
    }
}

/// The day at the scrubbed time: heart rate, strain, stress, caffeine, sleep, workout, note. A line with a value shows
/// its source word beside it; a blank line shows why (never a made-up number).
struct SundialTimeCard: View {
    let reading: DialScrubIndex.Reading

    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.text)
                .mgFont(.kicker)
                .foregroundStyle(colors.ink.color)
                .lineLimit(2)
            ForEach(reading.series) { line in
                row(line)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.card, radius: MGRadius.chip, shadow: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private func row(_ line: DialScrubIndex.SeriesLine) -> some View {
        if let value = line.value {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.label)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .lineLimit(1)
                if let source = line.source {
                    Text(source)
                        .mgFont(.unit)
                        .foregroundStyle(colors.mute.color)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.label)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("—")
                        .mgFont(.detail)
                        .foregroundStyle(colors.mute.color)
                }
                if let reason = line.reason {
                    Text(reason)
                        .mgFont(.unit)
                        .foregroundStyle(colors.mute.color)
                        .lineLimit(2)
                }
            }
        }
    }

    private var spoken: String {
        let parts = reading.series.map { line -> String in
            if let value = line.value { return "\(line.label) \(value)" + (line.source.map { ", \($0)" } ?? "") }
            return "\(line.label): none. \(line.reason ?? "")"
        }
        return ([reading.text] + parts).joined(separator: ". ")
    }
}
