import Foundation
import MGDomain

/// T9976 (Oct 17 2026): the HRV screen's suite block, shown on the HRV group (Explore > HRV). Every standard method
/// of the PC's `pc.hrv-suite@1`, one row per method with one cell per window (night, deep sleep, morning 5 min,
/// whole day); then Apple's and WHOOP's numbers as separate labelled sources, never mixed with these.
public struct HRVSuiteState: Equatable, Sendable {
    public var title: String
    /// What the numbers are: ours, from the strap's R-R, computed on the PC.
    public var intro: String
    /// Which PC result is shown ("pc.hrv-suite@1 · computed on PC · night of Oct 16 · ok"), or why there is none.
    public var resultLine: String
    /// One entry per window: what it is.
    public var windows: [HRVSuiteWindow]
    /// Empty when there is no PC result at all (r8h E2): the view then shows `resultLine` once, not 16 blank cards.
    public var methods: [HRVSuiteMethod]
    /// Heading of the other sources block.
    public var othersTitle: String
    public var others: [LabeledValue]
}

public struct HRVSuiteWindow: Equatable, Sendable, Identifiable {
    public var id: String          // night, deep, morning5, day
    public var title: String
    public var detail: String
}

public struct HRVSuiteMethod: Equatable, Sendable, Identifiable {
    public var id: String          // rmssd, sdnn, ...
    public var name: String
    /// One line: what it may mean, with the source and population its evidence comes from (written by the PC).
    public var meaning: String
    /// The standard's reference ("Task Force of ESC/NASPE 1996, ...").
    public var source: String
    public var cells: [HRVSuiteCell]
}

public struct HRVSuiteCell: Equatable, Sendable, Identifiable {
    public var id: String          // window id
    public var window: String      // "Night"
    public var value: DisplayValue
}
