import SwiftUI
import MGBLE
import MGContext
import MGDesign

// 0.6.0.12 — "Raw WHOOP 4.0 data": the once-a-second fields of the 4.0's history records from the latest stored records, each a
// raw count with a small chart of the last hours. Reached from Strap & sync › Device (WHOOP 4.0 selected) and from the Live tab.
// Everything here is "raw counts, decoded, untested": no unit, no % / °C / breaths per minute (CLAUDE.md rule 4). Gravity is the
// one exception, in g, and is also decoded, untested. Offsets: docs/research/WHOOP4-INVENTORY-2026-11-05.md section 4.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

struct Whoop4RawScreen: View {
    @ObservedObject var model: Whoop4RawModel
    /// Refresh the records / read the LED settings now (AppModel).
    var reload: () -> Void = {}
    var readLed: () -> Void = {}
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: MGSpace.m) {
                Text("Raw WHOOP 4.0 data")
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                    .padding(.top, MGSpace.m)
                Text("Raw counts, decoded, untested. These are the numbers the strap stores once a second, exactly as it sends them. "
                     + "They are not percentages, degrees or breaths per minute, and nothing here is calibrated.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(model.status)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if model.loading { ProgressView() }
                }
                MGButton("Refresh", style: .ghost) { reload() }
                if let latest = model.series.latest {
                    Text("Latest record: \(MGFormat.time(latest.date, calendar: calendar)), strap clock")
                        .mgFont(.kicker)
                        .foregroundStyle(colors.mute.color)
                    ForEach(Whoop4RawRecord.Field.allCases, id: \.self) { field in
                        Whoop4RawRow(field: field, latest: latest, points: model.series.series(field))
                    }
                }
                Whoop4LedReadsSection(model: model, latest: model.series.latest, readLed: readLed)
            }
            .padding(.bottom, 40)
        }
    }
}

/// One field: its name with the frame offset, the newest raw value, and a small chart of the last hours.
struct Whoop4RawRow: View {
    let field: Whoop4RawRecord.Field
    let latest: Whoop4RawRecord
    let points: [(at: Date, value: Double)]
    @Environment(\.mgColors) private var colors

    private var valueText: String {
        let v = field.value(latest)
        if field.unit != nil { return String(format: "%.3f", v) + " g" }
        return String(Int(v.rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                Spacer(minLength: 8)
                Text(valueText).mgFont(.wordValue).foregroundStyle(colors.ink.color)
            }
            RawSparkline(values: points.map(\.value))
                .frame(height: 36)
            Text(field.unit == nil ? "raw counts, decoded, untested" : "decoded, untested")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(field.title), \(valueText), raw count, decoded, untested")
    }
}

/// A small line of `values`, scaled to its own range.
struct RawSparkline: View {
    let values: [Double]
    @Environment(\.mgColors) private var colors

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 1e-9)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(colors.ink.color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            } else {
                Rectangle().fill(colors.rule.color).frame(height: 1).offset(y: geo.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// LED settings reads (GET_LED_DRIVE 40, GET_TIA_GAIN 42, GET_BIAS_OFFSET 44, body 00): a button, the newest reads as raw hex with the
/// wear state, and the strap's own LED drive from the latest history record beside them (frame 76 / 78) so the two can be compared.
/// Read-only. The bytes are not interpreted: nobody has published what they mean (raw, decoded, untested).
struct Whoop4LedReadsSection: View {
    @ObservedObject var model: Whoop4RawModel
    let latest: Whoop4RawRecord?
    let readLed: () -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LED settings (read only)").mgFont(.headline).foregroundStyle(colors.ink.color)
                .padding(.top, MGSpace.m)
            Text("Asks the strap for its LED drive (40), TIA gain (42) and bias offset (44), body 00, once each. It never changes "
                 + "anything on the strap. The same read runs by itself every 30 minutes from 10 PM to 8 AM while the 4.0 is "
                 + "connected. The replies are kept as raw hex with the time and whether the strap was on your wrist.")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            MGButton(model.ledReading ? "Reading…" : "Read LED settings", style: .ghost) { readLed() }
                .disabled(model.ledReading)
            if let latest {
                Text("The strap's own LED drive in the latest record: \(latest.ledDrive1) and \(latest.ledDrive2) (frame 76 and 78), raw counts, decoded, untested.")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.ledStoreError {
                Text("A read could not be saved: \(err)")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.ledReads.isEmpty {
                Text("No reads yet.").mgFont(.detail).foregroundStyle(colors.mute.color)
            }
            ForEach(Array(model.ledReads.prefix(12))) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(MGFormat.time(r.at, calendar: calendar)) · \(r.title) · "
                         + (r.worn.map { $0 ? "worn" : "not worn" } ?? "wear unknown") + " · \(r.result)")
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                    Text(r.replyHex.isEmpty ? (r.error ?? "no reply") : r.replyHex)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
