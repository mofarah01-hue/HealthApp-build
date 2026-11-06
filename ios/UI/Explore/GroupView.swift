import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Comparison group, open (UX-SPEC §11, pushed from "all methods" and from Explore › Methods). Every member the group
// runs, side by side: name + codename · value on its own scale · its own bands · rank · where it ran (the receipt's
// first word) · keep / drop. Drop hides, never deletes (BRIEF "Addition only + comparison groups"): a dropped
// method waits under "Show dropped" with a Restore button. Pure rendering of `GroupState`. Owner: WP-19.

struct GroupView: View {
    @Environment(\.mgColors) private var colors
    private let state: GroupState
    private let send: (UIIntent) -> Void

    init(state: GroupState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                ExplorePushHeader(kicker: "\(state.groupId) · comparison group", title: state.name)

                Text("Every method runs and sits side by side. The filled circle is the one you read. "
                     + "Keep or drop from ⋯ — dropping hides a method, it never deletes it. "
                     + "Ranks come from the comparison notes; your choice overrides them.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                membersBlock
                    .padding(.top, 14)

                // Wave 2: every metric name of the group (G-HRV: 13) with each member's value — GroupPipeline + PC.
                if !state.measures.isEmpty {
                    GroupMeasuresBlock(measures: state.measures, send: send)
                        .padding(.top, MGSpace.section)
                }

                // T9976: the PC's HRV suite, method x window, with Apple's SDNN and WHOOP's history kept apart.
                if let suite = state.hrvSuite {
                    HRVSuiteBlock(suite: suite, send: send)
                        .padding(.top, MGSpace.section)
                }

                // Tracker #7: older years from the PC, labelled with algorithm and source.
                GroupPCHistoryBlock(note: state.pcHistory, rows: state.pcRows, period: state.period, send: send)
                    .padding(.top, MGSpace.section)

                if let agreement = state.agreement {
                    Text("Agreement window")
                        .mgFont(.kicker)
                        .foregroundStyle(colors.ink2.color)
                        .padding(.top, MGSpace.section)
                    ExplorePeriodPicker(selected: state.period, send: send)
                        .padding(.top, 6)
                    Text(agreement)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                droppedBlock
            }
            .padding(.bottom, 40)
        }
        .exploreSampleBanner(state.sample)
        .environment(\.mgSend, send)
    }

    // MARK: Members

    @ViewBuilder private var membersBlock: some View {
        if state.members.isEmpty {
            ExploreBlankNote(state.dropped.isEmpty
                             ? "No methods are listed for this group."
                             : "Every method in this group is hidden. Use Show dropped to restore one.")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(state.members.enumerated()), id: \.element.id) { index, member in
                    ExploreMemberRow(member: member, groupId: state.groupId, showsRule: index > 0, send: send)
                }
            }
            .padding(.horizontal, 14)
            .mgSurface(.card, radius: MGRadius.card)
        }
    }

    // MARK: Dropped

    @ViewBuilder private var droppedBlock: some View {
        if !state.dropped.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    send(.showDropped(groupId: state.groupId))
                } label: {
                    HStack {
                        Text(state.showDropped ? "Hide dropped (\(state.dropped.count))"
                                               : "Show dropped (\(state.dropped.count))")
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.mute.color)
                            .rotationEffect(.degrees(state.showDropped ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: MGSpace.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(state.showDropped ? "open" : "closed")

                if state.showDropped {
                    Text("Dropped methods are hidden from Today and the strips. Nothing is deleted; Restore brings one back.")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(state.dropped.enumerated()), id: \.element.id) { index, member in
                            ExploreMemberRow(member: member, groupId: state.groupId, showsRule: index > 0, send: send)
                        }
                    }
                    .padding(.horizontal, 14)
                    .mgSurface(.card, radius: MGRadius.card)
                }
            }
            .padding(.top, MGSpace.section)
        }
    }
}

// MARK: - One member

/// A member row: radio (the method you read) · label + research tag · codename + rank · receipt (where it ran,
/// tier, when) · value on its own scale · its own bands · menu (Read this one, Keep, Drop / Restore).
struct ExploreMemberRow: View {
    @Environment(\.mgColors) private var colors
    private let member: MethodMember
    private let groupId: String
    private let showsRule: Bool
    private let send: (UIIntent) -> Void

    init(member: MethodMember, groupId: String, showsRule: Bool, send: @escaping (UIIntent) -> Void) {
        self.member = member
        self.groupId = groupId
        self.showsRule = showsRule
        self.send = send
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading

            // Bug 15 (round 2, 2026-10-14, M-143): tapping the member opens its own detail (name + variant).
            // r8h E5: the receipt is its own 44 pt Button beside the "open" Button, not nested inside it.
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    send(MethodsStrip.openIntent(groupId: groupId, member: member))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(member.label)
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if member.isResearch { ResearchTag() }
                            if member.isKept { ExploreMarkTag(text: "kept", spoken: "marked keep") }
                            if member.isDropped { ExploreMarkTag(text: "hidden", spoken: "dropped, hidden") }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .accessibilityHidden(true)
                        }
                        let sub = [member.codename, member.rank.map { "rank \($0)" }].compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty {
                            Text(sub).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(member.label)")
                if let receipt = member.value.receipt {
                    ReceiptLabel(receipt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                MemberValueView(member.value, size: .number)
                ExploreMemberBands(member: member)
                trailingControl
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if showsRule { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
        }
        .contextMenu { menuItems }
    }

    /// The radio for a live member; for a dropped one there is nothing to read, so a Restore arrow instead.
    @ViewBuilder private var leading: some View {
        if member.isDropped {
            Button {
                send(.markMethod(groupId: groupId, variant: member.variant, mark: .restore))
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.ink2.color)
                    .frame(width: 44, height: 44, alignment: .top)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore \(member.label)")
        } else {
            Button {
                send(.selectMethod(groupId: groupId, variant: member.variant))
            } label: {
                Circle()
                    .strokeBorder(member.isRead ? colors.ink.color : colors.ink2.color,
                                  lineWidth: member.isRead ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .frame(width: 44, height: 44, alignment: .top)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(member.isRead ? "\(member.label), the method you read" : "Read \(member.label)")
            .accessibilityAddTraits(member.isRead ? .isSelected : [])
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if member.isDropped {
            MGButton("Restore", style: .ghost) {
                send(.markMethod(groupId: groupId, variant: member.variant, mark: .restore))
            }
        } else {
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(colors.ink2.color)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(member.label)")
        }
    }

    @ViewBuilder private var menuItems: some View {
        if member.isDropped {
            Button("Restore") {
                send(.markMethod(groupId: groupId, variant: member.variant, mark: .restore))
            }
        } else {
            Button("Read this one") { send(.selectMethod(groupId: groupId, variant: member.variant)) }
            Button(member.isKept ? "Kept ✓" : "Keep") {
                send(.markMethod(groupId: groupId, variant: member.variant, mark: .keep))
            }
            Button("Drop (hides, never deletes)") {
                send(.markMethod(groupId: groupId, variant: member.variant, mark: .drop))
            }
        }
    }
}

// MARK: - A member's own bands

/// Where the value sits on ITS OWN three bands (UX §11): a 3-segment bar with a tick, and the band named in words so
/// colour is never the only code. A method that can't run shows no bar (its value already says why); a method
/// with a value but no bands says so.
struct ExploreMemberBands: View {
    @Environment(\.mgColors) private var colors
    private let member: MethodMember

    init(member: MethodMember) {
        self.member = member
    }

    var body: some View {
        if member.value.isBlank {
            EmptyView()
        } else if let band = member.bandIndex {
            VStack(alignment: .trailing, spacing: 2) {
                ExploreBandBar(bandIndex: band, position: member.position)
                    .frame(width: 84, height: 12)
                Text([ExploreText.bandName(band), member.scaleNote].compactMap { $0 }.joined(separator: " · "))
                    .mgFont(.receipt)
                    .foregroundStyle(colors.ink2.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(member.scaleNote ?? "no bands on this scale")
                .mgFont(.receipt)
                .foregroundStyle(colors.ink2.color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ExploreBandBar: View {
    @Environment(\.mgColors) private var colors
    private let bandIndex: Int
    private let position: Double?

    init(bandIndex: Int, position: Double?) {
        self.bandIndex = bandIndex
        self.position = position
    }

    var body: some View {
        Canvas { ctx, size in
            let third = size.width / 3
            let fills: [MGRGBA] = [colors.bandLow, colors.bandMid, colors.bandHigh]
            for i in 0..<3 {
                let rect = CGRect(x: CGFloat(i) * third + (i == 0 ? 0 : 1), y: (size.height - 6) / 2,
                                  width: third - (i == 0 ? 1 : 2), height: 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fills[i].color))
            }
            // The dot: the presenter's position (0…1) when given, else the middle of the member's band.
            let clamped = min(max(bandIndex, 0), 2)
            let pos = position.map { min(max($0, 0), 1) } ?? (Double(clamped) + 0.5) / 3
            let x = min(max(size.width * CGFloat(pos), 3), size.width - 3)
            let dot = CGRect(x: x - 3, y: (size.height - 6) / 2, width: 6, height: 6)
            ctx.fill(Path(ellipseIn: dot), with: .color(colors.ink.color))
        }
        .accessibilityHidden(true)
    }
}

/// A small outlined word next to a method's name ("kept", "hidden"): a mark Mo made, in words, not colour.
struct ExploreMarkTag: View {
    @Environment(\.mgColors) private var colors
    private let text: String
    private let spoken: String

    init(text: String, spoken: String) {
        self.text = text
        self.spoken = spoken
    }

    var body: some View {
        Text(text)
            .mgFont(.tag)
            .foregroundStyle(colors.ink2.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(colors.ink2.color, lineWidth: 1)
            }
            .accessibilityLabel(spoken)
    }
}
