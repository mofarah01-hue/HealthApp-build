import Foundation

/// T127 (Mo 2026-10-13): which raw PPG traces the Live graph draws. The view keeps this value; the choices are made here.
/// Which raw block is red or IR is NOT established (T20): "green / red / IR" follow OpenStrap's block map only
/// (0 green, 1 red, 3 IR, 4 ambient; noop leaves it unassigned) and every label says so.
public struct LivePPGSelection: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        /// Every block and slot, one graph each (the T20 view).
        case everyBlock
        /// Block 0, both slots, one graph each.
        case greenOnly
        /// Blocks 0, 1 and 3 on one graph, each scaled to its own peak so the shapes can be compared.
        case allThree

        public var title: String {
            switch self {
            case .everyBlock: return "Every block"
            case .greenOnly: return "Green only"
            case .allThree: return "Green, red, IR"
            }
        }
    }

    public var mode: Mode = .everyBlock

    public init(mode: Mode = .everyBlock) { self.mode = mode }

    public static let mapNote = "Green, red and IR follow OpenStrap's block map (block 0 green, 1 red, 3 IR) - decoded, untested."

    /// Block number -> colour name, from the map above.
    static let colours: [Int: String] = [0: "Green", 1: "Red", 3: "IR"]

    /// The graphs to draw from the waves of the raw PPG row (wave id = block x 2 + slot).
    public func graphs(_ waves: [OpticalWave]) -> [LivePPGGraph] {
        func graph(_ w: OpticalWave) -> LivePPGGraph { LivePPGGraph(id: w.id, series: [w]) }
        // WHOOP4-WIRE 6: the WHOOP 4.0's one waveform has no block, so every mode draws it as it is.
        if waves.contains(where: { $0.id == LiveWaves.whoop4OpticalID }) { return waves.map(graph) }
        switch mode {
        case .everyBlock:
            return waves.map(graph)
        case .greenOnly:
            return waves.filter { $0.id / 2 == 0 }.map(graph)
        case .allThree:
            let series: [OpticalWave] = waves.compactMap { w in
                guard let colour = Self.colours[w.id / 2] else { return nil }
                let peak = w.samples.map { abs($0) }.max() ?? 0
                let label = "\(colour) (unconfirmed) · block \(w.id / 2) · slot \(w.id % 2 == 0 ? "A" : "B")"
                return OpticalWave(id: w.id, label: label, samples: peak > 0 ? w.samples.map { $0 / peak } : w.samples)
            }
            return series.isEmpty ? [] : [LivePPGGraph(id: -1, series: series)]
        }
    }

    /// Height of one plot: taller than the 110 points of T146, and taller again on the side (landscape) view.
    public static func plotHeight(landscape: Bool) -> Double { landscape ? 230 : 170 }
}

/// One plot: one trace, or several overlaid (`allThree`).
public struct LivePPGGraph: Equatable, Sendable, Identifiable {
    public var id: Int
    public var series: [OpticalWave]

    public init(id: Int, series: [OpticalWave]) {
        self.id = id
        self.series = series
    }
}
