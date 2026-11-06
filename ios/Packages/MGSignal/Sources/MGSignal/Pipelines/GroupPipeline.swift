import Foundation
import MGDomain

// WP-22 GroupPipeline — every comparison group of ALGORITHM-COMPARISON.md that writes phone metrics, with all its
// members in rank order (1 best; unranked last), Mo's keep / drop marks (APP-117: the latest mark wins; drop HIDES a
// member, nothing is ever deleted) and addition-only extras (a stored member the catalogue does not list is still shown,
// unranked). Spelling of every (name, variant) = the metric registry (app/shared/contract/metric-registry.json) and
// WP-23b's presenter catalogue (MGContext/Presenters/GroupCatalogue.swift). Python mirror: gen_pipelines.py `GROUPS`,
// `group_view`; golden PIPE-GROUPS.json. WRITTEN, NOT COMPILED.

public struct GroupMemberDef: Sendable, Hashable {
    public var variant: String
    /// ALGORITHM-COMPARISON rank; nil = not ranked there.
    public var rank: Int?
    /// The window this member's metric is written under ("night", "day", "morning", "profile").
    public var window: String

    public init(variant: String, rank: Int?, window: String) {
        self.variant = variant
        self.rank = rank
        self.window = window
    }
}

/// One metric name compared across its members inside one group.
public struct GroupDef: Sendable, Hashable {
    public var groupId: String
    public var metric: String
    public var members: [GroupMemberDef]

    public init(groupId: String, metric: String, members: [GroupMemberDef]) {
        self.groupId = groupId
        self.metric = metric
        self.members = members
    }
}

public struct GroupMemberView: Sendable, Equatable {
    public var variant: String
    public var rank: Int?
    /// Mo's latest mark, nil = never marked.
    public var mark: MemberMark.Value?
    /// Dropped: hidden from the card, still stored and still listed here.
    public var hidden: Bool
    /// The stored metric (value or blank with its reason); nil = nothing stored for this member that day.
    public var metric: Metric?

    public init(variant: String, rank: Int?, mark: MemberMark.Value?, hidden: Bool, metric: Metric?) {
        self.variant = variant
        self.rank = rank
        self.mark = mark
        self.hidden = hidden
        self.metric = metric
    }
}

public struct GroupView: Sendable, Equatable {
    public var groupId: String
    public var metric: String
    public var members: [GroupMemberView]
    /// First visible member with a value, a kept one first (a hint; WP-23b's presenters choose what to read).
    public var primaryVariant: String?

    public init(groupId: String, metric: String, members: [GroupMemberView], primaryVariant: String?) {
        self.groupId = groupId
        self.metric = metric
        self.members = members
        self.primaryVariant = primaryVariant
    }
}

public enum GroupPipeline {
    static func m(_ v: String, _ r: Int?, _ w: String) -> GroupMemberDef { GroupMemberDef(variant: v, rank: r, window: w) }

    static func stage(_ name: String) -> GroupDef {
        GroupDef(groupId: "G-STAGE", metric: name, members: [m("ALG-031:A", 2, "night"), m("ALG-120", 3, "night"),
                                                             m("strap", nil, "night"), m("MS-21", 5, "night")])
    }

    static func single(_ g: String, _ name: String, _ v: String, _ r: Int?, _ w: String) -> GroupDef {
        GroupDef(groupId: g, metric: name, members: [m(v, r, w)])
    }

    /// Ranks: ALGORITHM-COMPARISON.md (2026-10-11). (G-TE / MS-04 training effect was removed 2026-10-17, r9p.)
    public static let catalogue: [GroupDef] = [
        single("G-HRV", "hrv_rmssd", "ALG-010", 1, "night"), single("G-HRV", "hrv_ln_rmssd", "ALG-010", 1, "night"),
        single("G-HRV", "hrv_sdnn", "ALG-010", 1, "night"), single("G-HRV", "hrv_pnn50", "ALG-010", 1, "night"),
        single("G-HRV", "hrv_sd1", "ALG-010", 1, "night"), single("G-HRV", "hrv_sd2", "ALG-010", 1, "night"),
        // LF/HF, LF, HF (ALG-011) are lab / research only since 2026-10-17 (D-HRV-WALK-1): not a group member.
        single("G-HRV", "hrv_sampen", "ALG-013", 2, "night"),
        GroupDef(groupId: "G-RESP", metric: "resp_rate",
                 members: [m("ALG-020", 1, "night"), m("ALG-121", 2, "night"), m("MS-07", 3, "night")]),
        single("G-SPO2", "spo2_strap_mean", "ALG-021", 1, "night"),
        single("G-SPO2", "spo2_strap_min", "ALG-021", 1, "night"),
        GroupDef(groupId: "G-TEMP", metric: "skin_temp_dev",
                 members: [m("ALG-110:100", nil, "night"), m("ALG-110:128", nil, "night")]),
        GroupDef(groupId: "G-READY", metric: "readiness",
                 members: [m("ALG-101", 1, "morning"), m("ALG-036", 2, "morning"), m("MS-18", 3, "morning"),
                           m("MS-20", 3, "morning"), m("MS-19", 4, "morning")]),
        stage("sleep_deep"), stage("sleep_light"), stage("sleep_rem"), stage("sleep_wake"),
        GroupDef(groupId: "G-LOAD", metric: "strain",
                 members: [m("MS-01", 1, "day"), m("ALG-036", 2, "day"), m("ALG-036:fit", 2, "day"),
                           m("ALG-036:trimp", 2, "day"), m("MS-02", 2, "day")]),
        GroupDef(groupId: "G-LOAD", metric: "acwr", members: [m("ALG-036", 2, "day"), m("MS-03", 3, "day")]),
        single("G-LOAD", "ctl", "ALG-036", 2, "day"), single("G-LOAD", "atl", "ALG-036", 2, "day"),
        single("G-LOAD", "tsb", "ALG-036", 2, "day"),
        GroupDef(groupId: "G-VO2", metric: "vo2max",
                 members: [m("ALG-036", 1, "day"), m("apple", 2, "day"), m("MS-05", 3, "day"), m("MS-06", 3, "day")]),
        single("G-VO2", "fitness_age", "ALG-133", nil, "day"),
        GroupDef(groupId: "G-HRMAX", metric: "hrmax",
                 members: [m("ALG-106:measured", 1, "profile"), m("ALG-106:tanaka", 2, "profile"),
                           m("MS-05:formula", 3, "profile"), m("whoop_export", nil, "day"),
                           m("apple_health", nil, "day")]),
        GroupDef(groupId: "G-STRESS", metric: "stress",
                 members: [m("ALG-123:daytime", 1, "day"), m("ALG-054", 2, "day"), m("MS-15", 4, "night")]),
        GroupDef(groupId: "G-AF", metric: "af_screen",
                 members: [m("ALG-013", 3, "night"), m("ALG-129:pnn70", 3, "night"), m("ALG-129:cosen", 3, "night")]),
        GroupDef(groupId: "G-CAL", metric: "calories_active",
                 members: [m("ALG-048:keytel", 1, "day"), m("ALG-048:keytel_vo2", 1, "day"),
                           m("ALG-048:keytel_motion", 1, "day"), m("apple", 2, "day")]),
        GroupDef(groupId: "G-CAL", metric: "calories_basal",
                 members: [m("ALG-048:mifflin", 2, "day"), m("ALG-048:cunningham", 2, "day")]),
        GroupDef(groupId: "G-STEPS", metric: "steps", members: [m("strap", 1, "day"), m("apple", 2, "day")]),
        GroupDef(groupId: "G-CAFF", metric: "caffeine_cutoff",
                 members: [m("ALG-061", 1, "day"), m("ALG-126:33mg", 2, "day"), m("ALG-126:drake6h", 3, "day")]),
        single("G-CAFF", "caffeine_bedtime", "ALG-060", nil, "night"),
    ]

    /// The latest mark per (group, variant): marks in the order given, a later or equal `at` replaces.
    static func latestMarks(_ marks: [MemberMark]) -> [String: MemberMark] {
        var latest: [String: MemberMark] = [:]
        for mk in marks {
            let k = "\(mk.groupId)|\(mk.variant)"
            if let cur = latest[k], mk.at < cur.at { continue }
            latest[k] = mk
        }
        return latest
    }

    /// The member's metric: its own window, else the first stored row of (name, variant) outside a workout (Mo's
    /// script writes "night" or "<n>min" for MS-07 / MS-15, as the PC).
    static func find(_ name: String, _ variant: String, window: String, in metrics: [Metric]) -> Metric? {
        metrics.first { $0.name == name && $0.variant == variant && $0.window == window }
            ?? metrics.first { $0.name == name && $0.variant == variant && !($0.window ?? "").hasPrefix("workout:") }
    }

    public static func view(_ def: GroupDef, metrics: [Metric], marks: [MemberMark]) -> GroupView {
        let latest = latestMarks(marks)
        let ordered = def.members.sorted { a, b in
            switch (a.rank, b.rank) {
            case let (x?, y?): return x != y ? x < y : a.variant < b.variant
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.variant < b.variant
            }
        }
        var rows: [GroupMemberView] = ordered.map { md in
            let mark = latest["\(def.groupId)|\(md.variant)"]?.mark
            return GroupMemberView(variant: md.variant, rank: md.rank, mark: mark, hidden: mark == .drop,
                                   metric: find(def.metric, md.variant, window: md.window, in: metrics))
        }
        // addition only: stored members the catalogue does not list, unranked, by variant
        let known = Set(def.members.map(\.variant))
        let extras = Set(metrics.filter { $0.name == def.metric && !($0.window ?? "").hasPrefix("workout:") }
            .compactMap(\.variant).filter { !known.contains($0) }).sorted()
        for v in extras {
            let mark = latest["\(def.groupId)|\(v)"]?.mark
            rows.append(GroupMemberView(variant: v, rank: nil, mark: mark, hidden: mark == .drop,
                                        metric: metrics.first { $0.name == def.metric && $0.variant == v
                                            && !($0.window ?? "").hasPrefix("workout:") }))
        }
        let visible = rows.filter { !$0.hidden && $0.metric?.value != nil }
        let primary = (visible.first { $0.mark == .keep } ?? visible.first)?.variant
        return GroupView(groupId: def.groupId, metric: def.metric, members: rows, primaryVariant: primary)
    }

    /// Every catalogued group for one day's metrics.
    public static func views(metrics: [Metric], marks: [MemberMark]) -> [GroupView] {
        catalogue.map { view($0, metrics: metrics, marks: marks) }
    }

    /// Reads the day's metrics and Mo's marks. Call whenever a group card or Explore's group screen opens.
    public static func run(day: LocalDay, source: any PipelineSource) async throws -> [GroupView] {
        views(metrics: try await source.metrics(on: day), marks: try await source.memberMarks())
    }
}
