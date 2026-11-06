import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Shared helpers for the Explore screens (WP-19, UX-SPEC §9 and §11).
// Presentation only: nothing here computes a statistic. Every number (medians, bands, EWMA, CUSUM marks, Spearman ρ,
// BH q-values) arrives in the state, built upstream from WP-09 / WP-15 functions (ARCHITECTURE §11 WP-19).
//
// Names are prefixed `Explore…` because every UI folder compiles into the one MGApp module.

extension View {
    /// The SAMPLE stripe pinned to the top while sample mode is on (BRIEF hard rule: every screen shows it).
    func exploreSampleBanner(_ sample: Bool) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if sample { SampleBanner() }
        }
    }
}

// MARK: - Words

enum ExploreText {
    /// "30 days" — the period in a sentence.
    static func periodLong(_ period: ExplorePeriod) -> String {
        switch period {
        case .today: return "today"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .year1: return "1 year"
        case .years2: return "2 years"
        case .years5: return "5 years"
        case .all: return "the whole history"
        case .custom(let r): return r.map { "\($0.label)" } ?? "the last 30 days (no custom range picked yet)"
        }
    }

    /// UX §9: the matrix footnote. `MatrixState.footnote` carries it; this is the fallback if a presenter sends none.
    static let matrixFootnote = "Correlation, not cause. Benjamini–Hochberg corrected across the grid."

    /// Spearman ρ as the heatmap prints it: "+0.42", "-0.31" (same format, so the numbers match cell for cell).
    static func rho(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    /// The label of a matrix row / column: "HRV, nightly RMSSD" → "HRV", "Training effect (aerobic)" → "Training effect".
    static func shortLabel(_ name: String) -> String {
        let head = name.components(separatedBy: CharacterSet(charactersIn: ",(")).first ?? name
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// "ALG-010 · phone · high · 06:58" → "ALG-010, phone, high, 06:58" (VoiceOver reads the middle dot badly).
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
    }

    static func bandName(_ index: Int) -> String {
        ["bottom band", "middle band", "top band"][min(max(index, 0), 2)]
    }
}

// MARK: - State → chart inputs

/// Turns state values into the MGDesign chart inputs. Sorting, de-duplicating by day and dropping non-finite numbers
/// is hygiene (a chart must not crash on a repeated day); no statistic is derived.
enum ExploreChartData {
    static func points(_ source: [DayPoint], calendar: Calendar) -> [ChartPoint] {
        var byDay: [String: DayPoint] = [:]
        for p in source { byDay[p.day.iso] = p }
        return byDay.values.sorted { $0.day < $1.day }.map { p in
            ChartPoint(date: p.day.start(in: calendar.timeZone), value: finite(p.value))
        }
    }

    static func markers(_ source: [GraphMarker], calendar: Calendar) -> [ChartMarker] {
        source.sorted { $0.day < $1.day }.map { m in
            ChartMarker(date: m.day.start(in: calendar.timeZone), label: m.label,
                        kind: m.kind == .healthVault ? .healthVault : .device)
        }
    }

    static func dates(_ days: [LocalDay], calendar: Calendar) -> [Date] {
        days.sorted().map { $0.start(in: calendar.timeZone) }
    }

    /// The shaded normal band, or nil when either edge is missing or they are reversed.
    static func band(low: Double?, high: Double?) -> ClosedRange<Double>? {
        guard let low, let high, low.isFinite, high.isFinite, low <= high else { return nil }
        return low...high
    }

    /// Days that really have a value (a chart needs two to draw a line).
    static func knownCount(_ points: [ChartPoint]) -> Int {
        points.filter { $0.value != nil }.count
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Decimals follow the data: whole numbers stay whole ("6200"), a narrow range gets two, else one.
    static func formatter(for points: [ChartPoint]) -> (Double) -> String {
        let values = points.compactMap { $0.value }
        guard let lo = values.min(), let hi = values.max() else {
            return { MGFormat.number($0, decimals: 1) }
        }
        let allWhole = values.allSatisfy { $0 == $0.rounded() }
        let decimals = allWhole ? 0 : ((hi - lo) < 1 ? 2 : 1)
        return { MGFormat.number($0, decimals: decimals) }
    }
}

// MARK: - Matrix choices

enum ExploreChoices {
    /// The metrics Mo can put in the matrix: every catalogue entry that opens a metric (research tools and the
    /// Methods list are not metrics), once each, in catalogue order. Search-independent: it reads the sections as given.
    static func metrics(from state: ExploreState) -> [MatrixMetric] {
        var seen = Set<String>()
        var out: [MatrixMetric] = []
        for section in state.catalogue {
            for entry in section.entries where entry.isMetric {
                if seen.insert(entry.key).inserted {
                    out.append(MatrixMetric(key: entry.key, name: entry.name))
                }
            }
        }
        return out
    }
}

extension CatalogueEntry {
    /// True when tapping it opens a metric (so it can be pinned and put in the matrix).
    var isMetric: Bool {
        if case .openMetric = intent { return true }
        return false
    }
}
