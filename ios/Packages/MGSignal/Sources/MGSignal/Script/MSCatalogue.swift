import Foundation
import MGDomain

/// One metric a script function produces: its registry name (ARCHITECTURE §8.3) or `ms_<what>` for the PC-only members,
/// and the unit written on the metric.
public struct MSOutput: Sendable, Hashable {
    public let name: String
    public let unit: String

    public init(name: String, unit: String) {
        self.name = name
        self.unit = unit
    }

    /// The registry key when `name` is a B1 registry metric (MS-01 … MS-07, MS-15, MS-18 … MS-21); nil for `ms_…`.
    public var registryKey: MetricKey? { MetricKey(rawValue: name) }
}

/// One of Mo's script functions (30: MS-22 removed 2026-10-17) (ALGORITHM-REQUIREMENTS §12) with the codename kept from his script.
public struct MSEntry: Sendable, Hashable {
    /// "MS-18"
    public let id: String
    /// The Python function name in `whoop_all_metrics_master_fixed.py`; for MS-11 … 14, 16, 17, 24, 26, 27, 29 (relative trends since
    /// 2026-10-17, D-TRENDS-1) the entry point in `pclab/mglab/ref/trends.py`.
    public let function: String
    /// Short codename from the script (Loop, Orchard, Aurora …); nil when the script gives none.
    public let codename: String?
    /// Comparison group (ALGORITHM-REQUIREMENTS §13).
    public let group: String
    /// True when MGSignal/Script holds a Swift port (phone tier, ARCHITECTURE §8.1); false = PC only.
    public let ported: Bool
    /// Empty for MS-31: its outputs are named by the keys asked for.
    public let outputs: [MSOutput]

    public init(id: String, function: String, codename: String?, group: String, ported: Bool, outputs: [MSOutput]) {
        self.id = id
        self.function = function
        self.codename = codename
        self.group = group
        self.ported = ported
        self.outputs = outputs
    }

    /// `Metric.method` text: "MS-18 recovery_loop (Loop)" — codename kept, as on the PC (ms_runner.py `method_of`).
    public var method: String {
        if let codename { return "\(id) \(function) (\(codename))" }
        return "\(id) \(function)"
    }
}

/// The 30 functions, the script file they were ported from and the version string every metric carries.
/// The Python side (`mglab/ms_runner.py` FUNCTIONS) holds the same table; app/pclab/tests/test_ms_runner.py compares
/// the two and the script's sha256, so a changed script or table fails there before it reaches a metric.
public enum MSCatalogue {
    /// `Metric.paramsVersion` of every script metric: "fixed@" + first 12 hex of the sha256 of the FIXED script file the
    /// ports and goldens were made from (reference/whoop_all_metrics_master_fixed.py). The PC writes the same string.
    public static let paramsVersion = "fixed@1e34a20e7c7c"
    public static let scriptSha256 = "1e34a20e7c7cd78d5ed8bb0a3b658462c37c1e1c873f411eaf9fa6be847b3d9c"
    public static let scriptFile = "reference/whoop_all_metrics_master_fixed.py"
    public static let citation = "Mo's master script, fixed copy (reference/whoop_all_metrics_master_fixed.py, MS-01..31); "
        + "inputs per ARCHITECTURE.md 8.2; script sources as written, checked in ALGORITHM-REQUIREMENTS.md 12"

    public static func entry(_ id: String) -> MSEntry? { all.first { $0.id == id } }

    /// The ids that have a Swift port in this folder, in script order.
    public static var portedIDs: [String] { all.filter { $0.ported }.map { $0.id } }

    /// A `MetricSpec` for one registry-named output of a script function (producer `.script`, variant = the MS id,
    /// method with the codename, `paramsVersion` above), or nil when the id, the output or the registry name is unknown
    /// (MS-30, MS-31 and the PC-only members have no `MetricKey`). WP-22 supplies window, tier and source.
    public static func spec(_ id: String, output: String, window: String, tier: Tier, source: String) -> MetricSpec? {
        guard let item = entry(id), let out = item.outputs.first(where: { $0.name == output }),
              let key = out.registryKey else { return nil }
        return MetricSpec(key: key, unit: out.unit, group: item.group, variant: item.id, method: item.method,
                          tier: tier, source: source, window: window, producer: .script, citation: citation,
                          paramsVersion: paramsVersion)
    }

    // swiftlint:disable line_length
    private static func e(_ id: String, _ function: String, _ codename: String?, _ group: String, _ ported: Bool,
                          _ outputs: [(String, String)]) -> MSEntry {
        MSEntry(id: id, function: function, codename: codename, group: group, ported: ported,
                outputs: outputs.map { MSOutput(name: $0.0, unit: $0.1) })
    }

    /// In script order (ALGORITHM-REQUIREMENTS §12). One entry per line: the Python test parses these lines.
    public static let all: [MSEntry] = [
        e("MS-01", "trimp_banister", "Loop", "G-LOAD", true, [("strain", "au")]),
        e("MS-02", "trimp_edwards", "Rhythm-Lab", "G-LOAD", true, [("strain", "au")]),
        e("MS-03", "acl_ctl", "Rhythm-Lab / Fenix", "G-LOAD", true, [("acwr", "ratio")]),
        e("MS-05", "vo2max_orchard", "Orchard", "G-VO2", true, [("vo2max", "ml_kg_min")]),
        e("MS-06", "vo2max_fenix_firstbeat", "Fenix / Rhythm-Lab", "G-VO2", true, [("vo2max", "ml_kg_min")]),
        e("MS-07", "resp_rate_kratky", "Kratky-Lab", "G-RESP", true, [("resp_rate", "br_min")]),
        e("MS-08", "spo2_pulseinstitute_dst", "Pulse-Institute", "G-SPO2", false, [("ms_spo2_dst", "percent")]),
        e("MS-09", "bp_fully_anchored", nil, "G-BP", false, [("ms_bp_sbp", "mmHg"), ("ms_bp_dbp", "mmHg")]),
        e("MS-10", "ahi_odi_lumen", "Lumen", "G-APNEA", false, [("ms_odi", "events_per_h"), ("ms_ahi", "events_per_h")]),
        e("MS-11", "ms11", nil, "G-SV", false, [("ms_stroke_volume", "bpm")]),
        e("MS-12", "ms12", nil, "G-VASC", false, [("ms_cfpwv", "ms")]),
        e("MS-13", "ms13", nil, "G-VASC", false, [("ms_stiffness_index", "m_s")]),
        e("MS-14", "ms14", nil, "G-VASC", false, [("ms_ppg_aix", "pct_points")]),
        e("MS-15", "hrv_stress_esc", "ESC-TF", "G-STRESS", true, [("stress", "score_0_100")]),
        e("MS-16", "ms16", nil, "G-LVEDP", false, [("ms_lvedp_anchor", "ratio")]),
        e("MS-17", "ms17", nil, "G-LVEDP", false, [("ms_lvedp_index", "bpm")]),
        e("MS-18", "recovery_loop", "Loop", "G-READY", true, [("readiness", "score_0_100")]),
        e("MS-19", "readiness_orchard", "Orchard", "G-READY", true, [("readiness", "score_0_10")]),
        e("MS-20", "readiness_aura", "Aurora", "G-READY", true, [("readiness", "score_0_100")]),
        e("MS-21", "sleep_stage_ppg", nil, "G-STAGE", true, [("sleep_deep", "min"), ("sleep_light", "min"), ("sleep_rem", "min"), ("sleep_wake", "min")]),
        e("MS-23", "blood_lab_prior", "Blood-Lab", "G-LABS", false, [("ms_lab_hba1c", "pct"), ("ms_lab_apob", "nmol_l"), ("ms_lab_ntprobnp", "ng_l"), ("ms_lab_ferritin", "as_reported"), ("ms_lab_homa_ir", "index")]),
        e("MS-24", "ms24", nil, "G-LABS", false, [("ms_genetic_bp_prior", "flag")]),
        e("MS-25", "testosterone_proxy", nil, "G-HORMONE", false, [("ms_testosterone_proxy", "index_0_1")]),
        e("MS-26", "ms26", nil, "G-HORMONE", false, [("ms_cortisol_car_proxy", "ln_ms")]),
        e("MS-27", "ms27", nil, "G-GLUCOSE", false, [("ms_glucose_risk_proxy", "bpm")]),
        e("MS-29", "ms29", nil, "G-MUSCLE", false, [("ms_muscle_injury_proxy", "count")]),
        e("MS-30", "sqi", nil, "G-SQI", true, [("ms_sqi", "weight_0_1")]),
        e("MS-31", "fuse", nil, "G-SQI", true, []),
    ]
    // swiftlint:enable line_length
}
