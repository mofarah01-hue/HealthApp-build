import Foundation
import MGDomain

/// One comparison group, quiet (UX §11, Vernier): collapsed strip "Recovery · 5 methods ›", open = one row per member.
public struct MethodsStripState: Equatable, Sendable {
    public var sample: Bool
    /// "G-READY".
    public var groupId: String
    /// "Recovery · 5 methods".
    public var title: String
    /// Dropped members are not in here (they hide, never delete); see `droppedCount`.
    public var members: [MethodMember]
    /// "4 in the top band, 1 in the middle. Reading ours until you choose."
    public var caption: String
    /// "Agreement, 30 days: …" (ALG-079), open state footer.
    public var agreement: String?
    public var droppedCount: Int
    /// Groups without a shared band scale collapse to one values line instead of the 3-band strip (UX §11).
    public var valuesLineOnly: Bool
    public var isExpanded: Bool

    public init(sample: Bool, groupId: String, title: String, members: [MethodMember], caption: String,
                agreement: String?, droppedCount: Int, valuesLineOnly: Bool, isExpanded: Bool = false) {
        self.sample = sample
        self.groupId = groupId
        self.title = title
        self.members = members
        self.caption = caption
        self.agreement = agreement
        self.droppedCount = droppedCount
        self.valuesLineOnly = valuesLineOnly
        self.isExpanded = isExpanded
    }

    /// The member Mo reads (bold tick).
    public var readMember: MethodMember? { members.first { $0.isRead } }
}

public struct MethodMember: Equatable, Sendable, Identifiable {
    /// Contract `variant`.
    public var variant: String
    /// "Loop".
    public var label: String
    /// "MS-18 recovery_loop" / "ALG-101".
    public var codename: String?
    /// The value on its own scale, or "—" + why ("needs a cuff").
    public var value: DisplayValue
    /// "/100 · green ≥ 67".
    public var scaleNote: String?
    /// Where the value sits on its own bands: 0 bottom, 1 middle, 2 top; nil when it can't run or has no bands.
    public var bandIndex: Int?
    /// Position inside the strip 0…1 (its own bands' thirds); nil = no tick.
    public var position: Double?
    public var isRead: Bool
    public var isResearch: Bool
    /// Rank 1–5 from ALGORITHM-COMPARISON.md; nil = unranked.
    public var rank: Int?
    /// Mo marked it "Keep" (long-press, UX §10). Added for WP-19 with main's OK, 2026-10-11.
    public var isKept: Bool
    /// Mo marked it "Drop": hidden, never deleted (UX §11); shown only under "Show dropped".
    public var isDropped: Bool
    /// Bug 1/15 (round 2, 2026-10-14): the registry metric name this member reads ("hrv_sdnn"), so a row opens that
    /// member's own detail and two members sharing one variant (ALG-010 writes RMSSD, SDNN, pNN50, ...) stay apart.
    /// Empty = not known (older callers); the row then opens the group's About instead.
    public var name: String

    public init(variant: String, label: String, codename: String?, value: DisplayValue, scaleNote: String? = nil,
                bandIndex: Int?, position: Double? = nil, isRead: Bool, isResearch: Bool, rank: Int?,
                isKept: Bool = false, isDropped: Bool = false, name: String = "") {
        self.name = name
        self.variant = variant
        self.label = label
        self.codename = codename
        self.value = value
        self.scaleNote = scaleNote
        self.bandIndex = bandIndex
        self.position = position
        self.isRead = isRead
        self.isResearch = isResearch
        self.rank = rank
        self.isKept = isKept
        self.isDropped = isDropped
    }

    /// Unique per row: name + variant (a variant alone repeats in the HRV group, bug 1).
    public var id: String { name.isEmpty ? variant : "\(name)|\(variant)" }
}
