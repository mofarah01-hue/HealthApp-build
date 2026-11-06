import Foundation
import MGDomain

// WP-22 MatrixPipeline — feeds APP-104 (Explore › Matrix, WP-19): one column per chosen metric (name, variant, window),
// one value per local day (the first stored row, as everywhere else), then WP-09's ALG-079 Spearman ρ with one
// Benjamini–Hochberg family; a cell with fewer than 14 paired days stays blank "too few days" (the diagonal is ρ 1 by
// definition, WP-19). Python mirror: gen_pipelines.py `matrix`; golden PIPE-MATRIX.json. WRITTEN, NOT COMPILED.

public struct MatrixKey: Sendable, Hashable {
    public var name: String
    public var variant: String?
    public var window: String?

    public init(name: String, variant: String?, window: String?) {
        self.name = name
        self.variant = variant
        self.window = window
    }

    /// "name|variant|window" — the column name the matrix carries.
    public var label: String { "\(name)|\(variant ?? "")|\(window ?? "")" }
}

public enum MatrixPipeline {
    /// Columns over the `days` days ending `end` (inclusive), oldest first, index-aligned (nil = no value that day).
    public static func columns(history: MetricHistory, keys: [MatrixKey], end: LocalDay,
                               days: Int) -> [String: [Double?]] {
        var out: [String: [Double?]] = [:]
        guard days > 0 else { return out }
        for k in keys {
            out[k.label] = (0..<days).reversed().map {
                history.value(k.name, variant: k.variant, window: k.window, on: end.adding(days: -$0))
            }
        }
        return out
    }

    public static func matrix(history: MetricHistory, keys: [MatrixKey], end: LocalDay, days: Int) -> ALG079.Matrix {
        ALG079.spearmanMatrix(names: keys.map(\.label), columns: columns(history: history, keys: keys, end: end,
                                                                         days: days),
                              minPairs: PipelineConstants.matrixMinPairs)
    }

    /// Explore's Compare with a lag: x on day t against y on day t + lag (ALG-079 spearmanLagged).
    public static func lagged(history: MetricHistory, x: MatrixKey, y: MatrixKey, lag: Int, end: LocalDay,
                              days: Int) -> Computed<ALG079.Correlation> {
        let cols = columns(history: history, keys: [x, y], end: end, days: days)
        return ALG079.spearmanLagged(cols[x.label] ?? [], cols[y.label] ?? [], lag: lag)
    }

    /// Reads the stored metrics of the period (including `end` itself). Call when the Matrix screen opens or its
    /// metric choice / period changes; ≤ 8 metrics (WP-19).
    public static func run(source: any PipelineSource, keys: [MatrixKey], end: LocalDay,
                           days: Int) async throws -> ALG079.Matrix {
        var h = MetricHistory()
        for k in 0..<max(0, days) {
            let d = end.adding(days: -k)
            let ms = try await source.metrics(on: d)
            if !ms.isEmpty { h.metrics[d] = ms }
        }
        return matrix(history: h, keys: keys, end: end, days: days)
    }
}
