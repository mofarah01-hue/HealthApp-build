import AppIntents
import SwiftUI
import WidgetKit

// WP-27 — the Lock Screen widgets (APP-016).
//   circular     a vape-hit button with today's count
//   rectangular  next medication and last vape; each row is a button (medication taken now / vape hit now)
// The system draws Lock Screen widgets in its own tint, so these use text and symbols only, no theme colours.
// The medication row is privacy-sensitive: on a locked phone the system blanks its text (name and time).

struct QuickLogLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickLogEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    // MARK: circular

    @ViewBuilder
    private var circular: some View {
        switch entry.state {
        case .ready(let model):
            if model.buttonsEnabled {
                Button(intent: WidgetLogVapeHitIntent(surface: .widget)) {
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Image(systemName: "wind")
                                .font(.system(size: 14, weight: .semibold))
                                .widgetAccentable()
                            Text(verbatim: model.vapeCountText)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                        }
                    }
                }
                .buttonStyle(QuickLogPressButtonStyle())
                .accessibilityLabel("Log a vape hit. \(model.vapeCountText) today.")
            } else {
                circularNote(symbol: "wind", text: "Off")
            }
        case .openMG:
            circularNote(symbol: "arrow.up.forward.app", text: "Open MG")
        case .noSharedStorage:
            circularNote(symbol: "exclamationmark.triangle", text: "No storage")
        }
    }

    private func circularNote(symbol: String, text: String) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: text)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    // MARK: rectangular

    @ViewBuilder
    private var rectangular: some View {
        switch entry.state {
        case .ready(let model):
            if model.buttonsEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    Button(intent: WidgetLogMedicationIntent(presetId: model.med.preset.presetId, surface: .widget)) {
                        row(symbol: "pills", text: medLine(model))
                            .privacySensitive()
                    }
                    .buttonStyle(QuickLogPressButtonStyle())
                    .accessibilityLabel("Log \(model.med.preset.name) taken now")

                    Button(intent: WidgetLogVapeHitIntent(surface: .widget)) {
                        row(symbol: "wind", text: vapeLine(model))
                    }
                    .buttonStyle(QuickLogPressButtonStyle())
                    .accessibilityLabel("Log a vape hit. \(vapeLine(model))")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                row(symbol: "wind", text: "Buttons are off in MG")
            }
        case .openMG:
            row(symbol: "arrow.up.forward.app", text: "Open MG once")
        case .noSharedStorage:
            row(symbol: "exclamationmark.triangle", text: "MG has no shared storage here")
        }
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .widgetAccentable()
                .frame(width: 16)
            Text(verbatim: text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "<name> 08:00" · "<name> due 08:00" · "<name> taken 08:12" · "<name> tmrw 08:00" · "<name>" (nothing scheduled).
    private func medLine(_ model: QuickLogModel) -> String {
        guard let detail = QuickLogFormat.medDetail(model.med, at: entry.date, calendar: .current) else {
            return model.med.preset.name
        }
        return "\(model.med.preset.name) \(detail)"
    }

    /// "Vape 7 today · 42 min" · "Vape 0 today · no hit on record".
    private func vapeLine(_ model: QuickLogModel) -> String {
        let last = QuickLogFormat.lastVape(model.lastVapeAt, now: entry.date)
        return "Vape \(model.vapeCountText) today · \(last)"
    }
}
