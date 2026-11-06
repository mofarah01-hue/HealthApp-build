import Foundation
import MGDomain

// Wave 4 (2026-10-11): the PC's LED identity experiment (pc.led-identity@1, app/pclab/mglab/alg/led_identity.py) as the
// phone reads it. Research only: which R20 blocks fill only inside the strap's SpO₂ windows (the candidate red / IR
// pair). Block 0 = green is the one channel every source agrees on (CAPABILITIES "Optical, SpO₂ and R22").

public enum LedExperiment {
    public static let modelId = "pc.led-identity"
    /// The only label established on this firmware.
    public static let greenBlock = 0
    /// OpenStrap's claim (no evidence given): red = block 1, IR = block 3. Used only as a stated assumption until the
    /// experiment names a pair.
    public static let claimedRedIR = (red: 1, ir: 3)

    public struct Status: Equatable, Sendable {
        /// The PC's sentence ("waiting: 1 of 3 strap SpO₂ windows covered …", "candidate red / IR pair: blocks 1 and 3 …").
        public var text: String
        /// Blocks the experiment names (empty until it has data).
        public var candidates: [Int]
    }

    public static let noResult = Status(text: "LED experiment: no result from the PC yet (needs raw optical at night).",
                                        candidates: [])

    /// The newest result (latest date).
    public static func status(_ results: [LabResult]) -> Status {
        var best: LabResult?
        for r in results where r.modelId == modelId && (r.status ?? "ok") == "ok" {
            if best == nil || r.date > best!.date { best = r }
        }
        guard let r = best else { return noResult }
        var text = noResult.text
        if case .string(let t)? = r.extra["text"] { text = "LED experiment: " + t }
        var cands: [Int] = []
        if case .object(let e)? = r.extra["experiment"], case .array(let a)? = e["candidates"] {
            for case .number(let d) in a { cands.append(Int(d)) }
        }
        return Status(text: text, candidates: cands)
    }

    /// The red / IR blocks to use and how sure that is: the experiment's pair when it named exactly two (still an
    /// inference: which one is red is not known), else OpenStrap's unproven claim.
    public static func redIR(_ st: Status) -> (red: Int, ir: Int, basis: String) {
        if st.candidates.count == 2 {
            return (st.candidates[0], st.candidates[1],
                    "blocks \(st.candidates[0]) / \(st.candidates[1]) from the LED experiment (which is red is assumed)")
        }
        return (claimedRedIR.red, claimedRedIR.ir,
                "blocks 1 (red) / 3 (IR) assumed from OpenStrap's unproven claim — the LED experiment has not confirmed them")
    }
}
