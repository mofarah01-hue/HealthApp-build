import Foundation
import MGDomain

// T9809. "Which source is the primary one for a displayed metric" is chosen by the PC (versions/primary.json, served in
// the GET /v1/results body, kept by the sync engine) so a change takes effect at the next sync with no app build.
// Only a KEY is ever read here: "phone:<variant>" picks a method already compiled into the app, "pc.<model>@<ver>[#variant]"
// picks a stored PC result. No code is downloaded.

enum PrimaryPick {
    enum Spec: Equatable {
        case phone(variant: String)
        case pc(model: String, version: String, variant: String?)

        init?(_ text: String) {
            if text.hasPrefix("phone:") {
                let v = String(text.dropFirst("phone:".count))
                guard !v.isEmpty else { return nil }
                self = .phone(variant: v)
            } else if text.hasPrefix("pc."), let at = text.firstIndex(of: "@") {
                let model = String(text[..<at])
                var version = String(text[text.index(after: at)...])
                var variant: String?
                if let hash = version.firstIndex(of: "#") {
                    variant = String(version[version.index(after: hash)...])
                    version = String(version[..<hash])
                }
                guard !version.isEmpty else { return nil }
                self = .pc(model: model, version: version, variant: variant)
            } else {
                return nil
            }
        }
    }

    /// The PC result's value for `name` the map asks for: the newest result of that model and version, for `day`, holding
    /// a valued PC metric of that name (and variant, when the spec names one) in EXACTLY the asked `window` (nil only
    /// matches nil; a row with no window counts as `defaultWindow`) and EXACTLY the phone's `unit`. Nil = not there (yet).
    static func pcMetric(_ name: String, model: String, version: String, variant: String?, day: LocalDay,
                         window: String?, defaultWindow: String? = nil, unit: String, in results: [LabResult]) -> Metric? {
        for r in results where r.modelId == model && r.modelVersion == version && r.date == day && r.status != "error" {
            if let m = r.metrics.first(where: {
                $0.name == name && $0.value?.isFinite == true && $0.computedOn == .pc && !ImportedHistory.isImported($0)
                    && (variant == nil || $0.variant == variant) && ($0.window ?? defaultWindow) == window && $0.unit == unit
            }) {
                return m
            }
        }
        return nil
    }

    /// T9972: the id of a primary map, FNV-1a 32-bit over the sorted "name=source" lines + newline as 8 hex digits. The PC computes
    /// the same (sync_api.py `primary_version`, pinned values in both test suites), so About shows the id without a sync field.
    static func mapVersion(_ map: [String: String]) -> String {
        var h: UInt32 = 0x811C9DC5
        for k in map.keys.sorted() {
            for b in (k + "=" + map[k]! + "\n").utf8 { h = (h ^ UInt32(b)) &* 0x01000193 }
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// Settings > About line: which map this phone is obeying.
    public static func mapLine(_ map: [String: String]) -> String {
        if map.isEmpty { return "Algorithm map: none from the PC, so the app uses its own choices" }
        let pc = map.values.filter { $0.hasPrefix("pc.") }.count
        return "Algorithm map \(mapVersion(map)) from the PC: \(map.count) metric\(map.count == 1 ? "" : "s"), \(pc) from PC results"
    }

    static let pendingCaption = "PC result pending"

    /// The caption of a PC-picked metric: "PC · pc.sleep-stager@2".
    static func caption(model: String, version: String) -> String { "PC · \(model)@\(version)" }
}

/// What the primary map says for one metric: always something to show (`metric` may be a blank carrying its reason).
struct PrimaryChoice {
    var metric: Metric
    var label: String?
}

extension PresenterSnapshot {
    /// THE resolver every primary display goes through (`metric`, `dayStrain`, `dayStress`, group read variants).
    /// nil = the map names nothing usable for `name` (the app's usual rule applies, no label). Otherwise the answer is
    /// final: a "phone:<variant>" pick -> that phone row; a "pc.<model>@<ver>" pick -> that PC result when model, version,
    /// day, window and unit all match, else the phone-computed value of the exact window labelled "PC result pending",
    /// else a blank with the reason. Never another PC model, another window or imported history.
    /// `rows` = stored rows of `name` the caller shows from; `window` = the window asked for (nil = rows without one).
    func primaryPick(_ name: String, among rows: [Metric], window: String? = nil,
                     defaultWindow: String? = nil) -> PrimaryChoice? {
        guard let text = primary[name], let spec = PrimaryPick.Spec(text) else { return nil }
        // A caller that names no window means the window its rows share (as `readVariant` does); rows in several
        // windows keep the old rule (nil matches only rows without a window).
        let rowWindows = Set(rows.filter { $0.name == name && $0.computedOn != .pc && !ImportedHistory.isImported($0) }
            .map { $0.window ?? defaultWindow })
        let window: String? = window ?? (rowWindows.count == 1 ? rowWindows.first! : nil)
        let phone = rows.filter {
            $0.name == name && $0.computedOn != .pc && !ImportedHistory.isImported($0)
                && ($0.window ?? defaultWindow) == window
        }
        let valued = phone.filter { $0.value?.isFinite == true }
        switch spec {
        case .phone(let variant):
            guard let m = valued.first(where: { $0.variant == variant }) else { return nil }
            return PrimaryChoice(metric: m, label: nil)
        case .pc(let model, let version, let variant):
            let units = Set(phone.map(\.unit))
            if units.count == 1, let unit = units.first,
               let m = PrimaryPick.pcMetric(name, model: model, version: version, variant: variant, day: day, window: window,
                                            defaultWindow: defaultWindow, unit: unit, in: pcResults) {
                // V3 (2026-10-15): a PC sleep result that does not match the strap night is not shown, even when picked.
                let sleepModel = PresenterSnapshot.pcSleepVariants.contains(model)
                    && PresenterSnapshot.sleepNames.contains(name)
                if sleepModel, pcSleepRejects(model)
                    || (name == MetricKey.sleepTotal.rawValue && pcSleepGateFails(total: m.value, window: pcWindow(model))) {
                    if let ph = shown(valued, honourMap: false) {
                        return PrimaryChoice(metric: ph, label: PresenterSnapshot.pcRejectedLabel)
                    }
                } else {
                    return PrimaryChoice(metric: m, label: PrimaryPick.caption(model: model, version: version))
                }
            }
            if let m = shown(valued, honourMap: false) { return PrimaryChoice(metric: m, label: PrimaryPick.pendingCaption) }
            let why = units.count > 1 ? "its rows have different units, so a PC result cannot be checked against them"
                : "the phone has no value for this window to check the unit against"
            let blank = Metric(name: name, value: nil, unit: units.first ?? "", tier: .estimate, source: "primary-map",
                               window: window, computedOn: .phone, at: now,
                               note: "PC result pending (\(model)@\(version) not stored for this day yet), and \(why).")
            return PrimaryChoice(metric: blank, label: PrimaryPick.pendingCaption)
        }
    }

    /// The caption for a shown metric: the PC pick's label, or "PC result pending" when the map wants a PC result that has
    /// not arrived and `m` is the phone value (or the blank) shown instead; nil otherwise.
    func primaryLabel(_ m: Metric?) -> String? {
        guard let m, let choice = primaryPick(m.name, among: all(m.name), window: m.window) else { return nil }
        if choice.label == PrimaryPick.pendingCaption {
            return m.computedOn != .pc && !ImportedHistory.isImported(m) ? choice.label : nil
        }
        return choice.metric == m ? choice.label : nil
    }
}
