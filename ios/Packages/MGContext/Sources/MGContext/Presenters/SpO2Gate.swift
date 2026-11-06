import Foundation
import MGDomain

// Wave 4 (#25, 2026-10-11): how the strap's own SpO₂ byte is shown, from the PC's gate result (pc.spo2-gate@1,
// app/pclab/mglab/alg/spo2_gate.py = noop's per-strap promotion gate against WHOOP's own SpO₂). Until the gate passes,
// the raw byte is shown WITH an estimated % next to it, labelled "estimate — not checked against WHOOP" (CLAUDE.md rule 4
// exception, Mo 2026-10-11 19:31 PT; until 19:40 PT this file showed the byte only, no %). After the gate passes, the
// variant it checked (ALG-021:windows) reads as a plain % with the gate as its receipt. Pure: no clock, no I/O.

public enum SpO2Gate {
    /// THE pre-gate wording, in one place (Mo's decision of 19:31 PT, rule 4 exception: raw byte AND an estimated %,
    /// always with this label until the per-strap check passes). It used to read "strap byte, uncalibrated", byte only.
    public static let preGateLabel = "estimate — not checked against WHOOP"
    /// The estimated % next to the byte before the gate passes: the in-band byte read as a % (whoop-rs gen5.rs L30-31).
    static func estimateUnit(_ v: Double) -> String { "≈ \(MGFormat.number(v, decimals: 0)) % estimate" }
    /// #62, closed by research (CAPABILITIES "Optical, SpO₂ and R22": "There is no GET_SPO2 BLE command").
    public static let noOnDemand = "The strap measures SpO₂ only on its own, while you sleep (about 30 s every 20 min). "
        + "No known strap command takes a reading now or every hour, so the app cannot ask for one."
    public static let modelId = "pc.spo2-gate"
    /// The member the gate validated; only it ever turns into a %.
    public static let gatedVariant = "ALG-021:windows"
    public static let names: Set<String> = [MetricKey.spo2StrapMean.rawValue, MetricKey.spo2StrapMin.rawValue]

    public enum State: String, Sendable, Equatable {
        /// No gate result from the PC yet.
        case none
        case waiting
        case waitingScan = "waiting_scan"
        case pass
        case fail
        case featureAbsent = "feature_absent"
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var pairedNights: Int
        public var needed: Int
        public var r: Double?
        public var mae: Double?
        public var bias: Double?
        /// The PC's one-line verdict ("waiting: 2 of 5 paired nights", "pass: agrees with WHOOP over 6 nights …").
        public var text: String
        /// One line per criterion ("pass  r >= 0.7: 0.985").
        public var criteria: [String]
        public var date: LocalDay?

        public var passed: Bool { state == .pass }

        /// The receipt line a % carries after the gate passed.
        public var receiptLine: String {
            "agrees with WHOOP over \(pairedNights) nights, r = \(r.map { MGFormat.number($0, decimals: 2) } ?? "—"), "
                + "error \(mae.map { MGFormat.number($0, decimals: 2) } ?? "—") point"
        }

        static let noResult = Status(state: .none, pairedNights: 0, needed: 5, r: nil, mae: nil, bias: nil,
                                     text: "waiting: 0 of 5 paired nights (no check from the PC yet)", criteria: [],
                                     date: nil)
    }

    /// The newest gate result (latest date; the newest seq first within a date, as `pcResults` arrive).
    public static func status(_ results: [LabResult]) -> Status {
        var best: LabResult?
        for r in results where r.modelId == modelId && (r.status ?? "ok") == "ok" {
            if best == nil || r.date > best!.date { best = r }
        }
        guard let r = best, case .object(let g)? = r.extra["gate"] else { return .noResult }
        func num(_ k: String) -> Double? {
            if case .number(let d)? = g[k] { return d }
            return nil
        }
        let state = g["status"].flatMap { v -> State? in
            if case .string(let s) = v { return State(rawValue: s) }
            return nil
        } ?? .none
        var lines: [String] = []
        if case .array(let pts)? = r.extra["points"] {
            for case .string(let p) in pts { lines.append(p) }
        }
        var text = Status.noResult.text
        if case .string(let t)? = r.extra["text"] { text = t }
        return Status(state: state, pairedNights: Int(num("paired_nights") ?? 0), needed: Int(num("needed") ?? 5),
                      r: num("r"), mae: num("mae"), bias: num("bias"), text: text, criteria: lines, date: r.date)
    }

    /// Short caption under the value (Today): the gate's state in a few words.
    public static func caption(_ st: Status) -> String {
        switch st.state {
        case .pass: return "checked against WHOOP"
        case .none, .waiting: return "\(preGateLabel) · \(st.pairedNights) of \(st.needed) nights"
        case .waitingScan: return "\(preGateLabel) · waiting for the byte scan"
        case .fail: return "\(preGateLabel) · did not match WHOOP"
        case .featureAbsent: return "the strap writes no SpO₂"
        }
    }

    /// The strap byte on screen: after a pass, `gatedVariant` as a plain % with the gate as its receipt; otherwise the
    /// raw byte (strap-raw style) with "≈ N % estimate" beside it and the estimate label in the receipt. A value outside
    /// 70–100 gets no %. nil = not a strap SpO₂ value (or no value): show it the ordinary way.
    static func percent(_ m: Metric, status: Status, sample: Bool) -> DisplayValue? {
        guard names.contains(m.name), let v = m.value, v.isFinite else { return nil }
        var receipt = MetricText.receipt(m)
        if status.passed, m.variant == gatedVariant {
            receipt.method = [m.method, status.receiptLine].compactMap { $0 }.joined(separator: " · ")
            return .value(text: MGFormat.number(v, decimals: 0), unit: "%", receipt: receipt, style: .plain, sample: sample)
        }
        guard v >= Double(inBandLow), v <= Double(inBandHigh) else { return nil }
        receipt.method = [m.method, preGateLabel].compactMap { $0 }.joined(separator: " · ")
        return .value(text: MGFormat.number(v, decimals: 0), unit: estimateUnit(v), receipt: receipt, style: .strapRaw,
                      sample: sample)
    }

    /// The strap's in-band reading range (MGSignal ALG021.readingRange; MGContext cannot import MGSignal).
    static let inBandLow = 70
    static let inBandHigh = 100

    /// The SpO₂ metric to show for `name`: the gated member when it has a value, else the ordinary pick.
    static func shown(_ s: PresenterSnapshot, _ name: String) -> Metric? {
        if let g = s.metric(name, variant: gatedVariant), g.value != nil { return g }
        return s.metric(name)
    }

    // MARK: #77 experimental spot reading (wave 4)

    /// "Measure now (experimental, 60 s)": 60 s of live raw optical, behind the raw-optical switch (rule 5).
    static func spotAction(_ s: PresenterSnapshot) -> ActionState {
        let running = (s.spo2SpotUntil.map { $0 > s.now }) ?? false
        var why: String?
        if s.sample {
            why = "Sample data is on."
        } else if !s.strapSync.rawOpticalWanted {
            why = "Turn on Raw optical in Strap & sync first (it uses strap battery)."
        } else if s.inputs.strap.link != .connected {
            why = "Needs the strap connected."
        } else if running {
            why = "Measuring — keep still for about a minute."
        }
        return ActionState(id: "spo2Spot", title: running ? "Measuring…" : "Measure now (experimental, 60 s)",
                           intent: .measureSpO2Now, enabled: why == nil, disabledReason: why)
    }

    /// The newest spot reading, worded as what it is.
    static func spotLines(_ s: PresenterSnapshot) -> [String] {
        let base = "Spot reading (experimental): 60 s of raw optical, ratio of red and IR pulses, 110 − 25·R. "
            + LedExperiment.redIR(LedExperiment.status(s.pcResults)).basis + "."
        guard let m = s.all(MetricKey.spo2Pct.rawValue).filter({ $0.variant == "ALG-022:spot" }).max(by: { $0.at < $1.at })
        else { return [base] }
        guard let v = m.value else { return [base, "Last try \(s.hm(m.at)): \(m.note ?? "no value")"] }
        return [base, "Last spot reading \(s.hm(m.at)): ≈ \(MGFormat.number(v, decimals: 0)) % — experimental estimate, "
                + "not checked against WHOOP. " + (m.note ?? "")]
    }

    /// The block on the SpO₂ metric screen: the gate's state, its criteria, and why there is no on-demand reading.
    static func detailLines(_ st: Status) -> [String] {
        var out: [String] = []
        switch st.state {
        case .pass:
            out.append("Shown as % since the PC's check passed: " + st.receiptLine + ". Only the in-window night value "
                       + "(ALG-021:windows) is shown as %; the other members stay raw bytes.")
        default:
            out.append("Shown as the raw strap byte with an estimated % (\(preGateLabel)) until the PC's check against "
                       + "WHOOP's own SpO₂ passes for this strap (noop's gate: 5 paired nights, r ≥ 0.7, error ≤ 1 point …).")
        }
        out.append("Check: " + st.text)
        out += st.criteria
        out.append(noOnDemand)
        return out
    }
}
