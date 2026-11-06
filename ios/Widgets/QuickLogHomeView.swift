import AppIntents
import SwiftUI
import WidgetKit

// WP-27 — the Home Screen widget (systemSmall): the four quick-log buttons (APP-016): Vape · Medication · Drink ·
// Symptom. The app's own pill row has Food as the fourth; Food needs a form, so it is not a one-tap event here
// (WP-24 has no food intent) and Symptom takes its place, as APP-016 words it ("vape hit, med, drink, symptom").
// Each button is an interactive-widget `Button(intent:)` (iOS 17) that writes one line to the App Group queue.

struct QuickLogPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuickLogHomeView: View {
    let entry: QuickLogEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { QuickLogBackground(theme: theme) }
    }

    private var theme: QuickLogTheme {
        if case .ready(let model) = entry.state { return model.theme }
        return .cream
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .ready(let model):
            QuickLogSmallReady(model: model, date: entry.date)
        case .openMG:
            QuickLogMessage(title: "Open MG once", detail: "Then the log buttons show up here.", palette: .make(.cream))
        case .noSharedStorage:
            QuickLogMessage(title: "No shared storage",
                            detail: "This install can't share data with the widget. Log in the app.",
                            palette: .make(.cream))
        }
    }
}

struct QuickLogMessage: View {
    let title: String
    let detail: String
    let palette: QuickLogPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "MG")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 0)
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(palette.ink)
                .minimumScaleFactor(0.8)
            Text(verbatim: detail)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct QuickLogSmallReady: View {
    let model: QuickLogModel
    let date: Date

    private var palette: QuickLogPalette { QuickLogPalette.make(model.theme) }

    var body: some View {
        if model.buttonsEnabled {
            VStack(spacing: 6) {
                header
                HStack(spacing: 6) {
                    vapeButton
                    medButton
                }
                HStack(spacing: 6) {
                    drinkButton
                    symptomButton
                }
            }
        } else {
            QuickLogMessage(title: "Buttons are off",
                            detail: "Switch them on in MG › Preferences › Quick-log surfaces.",
                            palette: palette)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(verbatim: "MG")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 2)
            Text(verbatim: QuickLogFormat.lastVape(model.lastVapeAt, now: date))
                .font(.system(size: 10))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var vapeButton: some View {
        Button(intent: WidgetLogVapeHitIntent(surface: .widget)) {
            QuickLogTile(symbol: "wind", title: "Vape", detail: "\(model.vapeCountText) today",
                         tint: palette.vape, palette: palette)
        }
        .buttonStyle(QuickLogPressButtonStyle())
        .accessibilityLabel("Log a vape hit. \(model.vapeCountText) today.")
    }

    private var medButton: some View {
        Button(intent: WidgetLogMedicationIntent(presetId: model.med.preset.presetId, surface: .widget)) {
            QuickLogTile(symbol: "pills", title: model.med.preset.name,
                         detail: QuickLogFormat.medDetail(model.med, at: date, calendar: .current),
                         tint: palette.med, palette: palette)
        }
        .buttonStyle(QuickLogPressButtonStyle())
        .accessibilityLabel("Log \(model.med.preset.name) taken now")
    }

    @ViewBuilder
    private var drinkButton: some View {
        if let open = model.drink.openName {
            Button(intent: WidgetFinishDrinkIntent(surface: .widget)) {
                QuickLogTile(symbol: "cup.and.saucer.fill", title: "Finish", detail: open,
                             tint: palette.drink, palette: palette)
            }
            .buttonStyle(QuickLogPressButtonStyle())
            .accessibilityLabel("Finish my \(open)")
        } else {
            Button(intent: WidgetStartDrinkIntent(name: model.drink.preset.name,
                                                  caffeineMg: model.drink.preset.caffeineMg,
                                                  surface: .widget)) {
                QuickLogTile(symbol: "cup.and.saucer", title: model.drink.preset.name,
                             detail: "\(Int(model.drink.preset.caffeineMg.rounded())) mg",
                             tint: palette.drink, palette: palette)
            }
            .buttonStyle(QuickLogPressButtonStyle())
            .accessibilityLabel("Start a \(model.drink.preset.name)")
        }
    }

    private var symptomButton: some View {
        Button(intent: WidgetLogSymptomIntent(kind: model.symptomKind, surface: .widget)) {
            QuickLogTile(symbol: "bandage", title: QuickLogFormat.symptomTitle(model.symptomKind), detail: "log now",
                         tint: palette.ink2, palette: palette)
        }
        .buttonStyle(QuickLogPressButtonStyle())
        .accessibilityLabel("Log \(QuickLogFormat.symptomTitle(model.symptomKind)) now")
    }
}

/// One button face: icon, name, one line of detail.
struct QuickLogTile: View {
    let symbol: String
    let title: String
    let detail: String?
    let tint: Color
    let palette: QuickLogPalette

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: detail ?? " ")
                .font(.system(size: 9.5))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.chip))
    }
}
