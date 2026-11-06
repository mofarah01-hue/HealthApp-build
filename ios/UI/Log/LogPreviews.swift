#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Log tab. `LogState.preview` is SAMPLE (banner on, logging disabled with its reason); the
// "live" variants flip `sample` off so the forms can be tried. The host applies the intents that change state, so rows
// open and close the way the presenter will drive them (one open at a time), a removed spine entry disappears, and the
// month opens. Everything else prints to the console.

struct LogPreviewHost: View {
    @State private var state: LogState
    let catalogue: LogCatalogue
    let theme: ThemeName

    init(state: LogState, catalogue: LogCatalogue = .standard, theme: ThemeName = .cream) {
        _state = State(initialValue: state)
        self.catalogue = catalogue
        self.theme = theme
    }

    var body: some View {
        LogView(state: state, catalogue: catalogue) { intent in apply(intent) }
            .mgTheme(theme)
    }

    private func apply(_ intent: UIIntent) {
        switch intent {
        case .toggleRow(let id):
            let wasOpen = state.items.first(where: { $0.id == id })?.isOpen ?? false
            for index in state.items.indices {
                state.items[index].isOpen = (state.items[index].id == id) && !wasOpen
            }
        case .removeEntry(let id):
            state.spine.removeAll { $0.id == id }
        case .openMonthGrid:
            if var grid = state.monthGrid {
                grid.isCollapsed.toggle()
                state.monthGrid = grid
            }
        default:
            print("Log intent:", intent)
        }
    }
}

extension LogState {
    /// The sample state with logging switched on and the opened rows' context lines filled in (previews only).
    static var logPreviewLive: LogState {
        var s = LogState.preview
        s.sample = false
        for index in s.items.indices {
            switch s.items[index].item {
            case .vape:
                s.items[index].expansion = NowRowExpansion(
                    lines: ["First hit after waking: 12 min · target 30 (plan week 2)", "7-day median: 17 a day"],
                    toggles: [ToggleState(id: "dtap", title: "Strap double-tap logs a hit",
                                          detail: "with a return buzz · APP-007", isOn: true,
                                          intent: .setQuickLogSurface(id: "dtap", enabled: false))])
            case .medication:
                s.items[index].expansion = NowRowExpansion(
                    lines: ["This month: 29 of 31 on time", "Label pharmacokinetics, shown as context only."])
            case .caffeine:
                s.items[index].expansion = NowRowExpansion(
                    lines: ["Today: DrinkA 07:30–08:15"],
                    chart: (0..<24).map { i in Double(max(0, 200 - i * 8)) },
                    chartCaption: "caffeine in you, to bedtime · 31 mg at 22:30, under your 33")
            default:
                break
            }
        }
        return s
    }

    /// Everything open-able, with one row open.
    static func logPreviewLiveOpen(_ item: LogItemID) -> LogState {
        var s = LogState.logPreviewLive
        for index in s.items.indices { s.items[index].isOpen = (s.items[index].item == item) }
        return s
    }

    /// T9507 acceptance state: every row, mixed button weights, one open panel, four spine events and four grid rows.
    static var logRestylePreview: LogState {
        var s = LogState.logPreviewLiveOpen(.caffeine)
        s.confirmCount = 1
        s.confirmList = [ConfirmItem(id: "preview-vape", title: "Vape hit 9:35 PM?",
                                     yes: .confirmDetected(id: "preview-vape", accepted: true),
                                     no: .confirmDetected(id: "preview-vape", accepted: false))]

        if let medication = s.items.firstIndex(where: { $0.item == .medication }) {
            s.items[medication].primaryButton = ActionState(
                id: "preview-dose", title: "Took 20 mg",
                intent: .quickLog(.medication(name: "Medication 20 mg")))
        }
        if let caffeine = s.items.firstIndex(where: { $0.item == .caffeine }),
           var expansion = s.items[caffeine].expansion {
            let explanation = PanelExplanation(
                id: "ALG-060", simple: "Population caffeine decay estimate.",
                technical: "A synthetic preview of exponential decay.", inputs: "Drink amount and time.",
                computation: "Applies absorption and half-life.", meaning: "Estimated caffeine remaining.", unit: "mg",
                source: "Preview catalogue.", blank: "No drink logged.")
            let option = AlgorithmPanelOption(id: "ALG-060", label: "Population half-life",
                                               explanation: explanation, metrics: [])
            expansion.algorithmPanel = AlgorithmPanelState(
                sample: true, title: "Caffeine decay", summary: "How the estimate falls through the evening.",
                selectedID: option.id, options: [option], note: "Preview values are invented.")
            s.items[caffeine].expansion = expansion
        }

        let spine = s.spine
        s.spine = [0, 1, 2, 4].compactMap { spine.indices.contains($0) ? spine[$0] : nil }
        if let grid = s.monthGrid {
            let logged = grid.days.indices.map { $0 < 12 ? Optional(true) : nil }
            let alternating = grid.days.indices.map { $0 < 12 && $0.isMultiple(of: 3) ? Optional(true) : nil }
            let one = grid.days.indices.map { $0 == 6 ? Optional(true) : nil }
            let medication = grid.rows.first?.marks ?? [Bool?](repeating: nil, count: grid.days.count)
            s.monthGrid = MonthGridState(title: grid.title, days: grid.days, rows: [
                MonthGridRow(item: .medication, title: "Medication", marks: medication),
                MonthGridRow(item: .vape, title: "Vape", marks: alternating),
                MonthGridRow(item: .caffeine, title: "Caffeine", marks: logged),
                MonthGridRow(item: .alcohol, title: "Alcohol", marks: one),
            ], isCollapsed: false)
        }
        return s
    }
}

#Preview("Log · Day") { LogPreviewHost(state: .logRestylePreview, theme: .cream) }
#Preview("Log · Night") { LogPreviewHost(state: .logRestylePreview, theme: .emerald) }
#Preview("Log · sample · rows closed") { LogPreviewHost(state: .preview) }
#Preview("Log · sample · month open") {
    var s = LogState.preview
    s.monthGrid?.isCollapsed = false
    return LogPreviewHost(state: s)
}
#Preview("Log · live · rows closed") { LogPreviewHost(state: .logPreviewLive) }
#Preview("Vape open") { LogPreviewHost(state: .logPreviewLiveOpen(.vape)) }
#Preview("Medication open") { LogPreviewHost(state: .logPreviewLiveOpen(.medication)) }
#Preview("Caffeine open") { LogPreviewHost(state: .logPreviewLiveOpen(.caffeine)) }
#Preview("Supplements open · with a list") {
    LogPreviewHost(state: .logPreviewLiveOpen(.supplements), catalogue: .previewWithSupplements)
}
#Preview("Food open") { LogPreviewHost(state: .logPreviewLiveOpen(.food)) }
#Preview("Symptom open") { LogPreviewHost(state: .logPreviewLiveOpen(.symptom)) }
#Preview("Sleepy open") { LogPreviewHost(state: .logPreviewLiveOpen(.sleepy)) }
#Preview("Alcohol open") { LogPreviewHost(state: .logPreviewLiveOpen(.alcohol)) }
#Preview("Note open") { LogPreviewHost(state: .logPreviewLiveOpen(.note)) }
#Preview("More open") { LogPreviewHost(state: .logPreviewLiveOpen(.more)) }
#Preview("Emerald · caffeine open") {
    LogPreviewHost(state: .logPreviewLiveOpen(.caffeine), theme: .emerald)
}
#Preview("Emerald low · symptom open") {
    LogPreviewHost(state: .logPreviewLiveOpen(.symptom), theme: .emeraldLow)
}
#Preview("Largest text · vape open") {
    LogPreviewHost(state: .logPreviewLiveOpen(.vape)).environment(\.dynamicTypeSize, .accessibility3)
}
#endif
