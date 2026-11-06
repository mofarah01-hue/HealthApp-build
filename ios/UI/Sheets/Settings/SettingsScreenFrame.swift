import SwiftUI
import MGContext
import MGDesign

// T10022 (r8p): the frame Settings and Preferences share. Header, sample banner, the first-row link to the other screen,
// then the clusters of `SettingsMap.clusters(on:)` with a chip row to jump between them. The two screens only differ in
// which blocks they draw, and `SettingsMap` decides that, so an item cannot be lost or drawn twice.
//
// R8e (S1): every block is a direct child of the LazyVStack (a `Group` adds no view of its own), so only the sections near
// the screen are built. R8e (S2): one label per cluster, used by the chip and the heading under it.
// R8p (S11): no Done button and no hidden bar: the system back button and edge swipe do the leaving.

struct SettingsScreenFrame<Block: View>: View {
    let screen: SettingsScreenName
    let sample: Bool
    /// What the screen is for, in the small line above the title.
    let kicker: String
    let openOther: () -> Void
    let block: (SettingsBlock) -> Block

    init(screen: SettingsScreenName, sample: Bool, kicker: String, openOther: @escaping () -> Void,
         @ViewBuilder block: @escaping (SettingsBlock) -> Block) {
        self.screen = screen
        self.sample = sample
        self.kicker = kicker
        self.openOther = openOther
        self.block = block
    }
    @Environment(\.mgColors) private var colors
    /// The chip last tapped (no scroll-position tracking: it re-ran the body on every cluster change, R8e S1).
    @State private var visibleCluster: String?
    /// The Today strap chip asks for the Device section (`SettingsScrollModel`).
    @ObservedObject private var scroll = SettingsScrollModel.shared

    private var clusters: [SettingsClusterSpec] { SettingsMap.clusters(on: screen) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    if sample {
                        LogHint(SettingsIntents.sampleReason)
                            .padding(.vertical, 6)
                    }

                    crossLink
                        .padding(.top, MGSpace.s)

                    ForEach(clusters) { cluster in
                        Group {
                            Text(cluster.label)
                                .mgFont(.kicker)
                                .foregroundStyle(colors.ink2.color)
                                .padding(.top, MGSpace.section)
                                .padding(.bottom, MGSpace.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                                .id(cluster.id)
                            ForEach(cluster.blocks) { b in
                                block(b)
                            }
                        }
                    }
                }
                .padding(.horizontal, MGSpace.gutter)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .background(colors.sheet.color.ignoresSafeArea())
            .task(id: scroll.target) { await goToRequested(proxy) }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if sample { SampleBanner() }
                    clusterIndex(proxy: proxy)
                }
                .background(colors.sheet.color)
            }
        }
    }

    /// A cluster asked for from outside (the strap chip): scroll to it once the screen has laid out, then clear the request.
    private func goToRequested(_ proxy: ScrollViewProxy) async {
        guard screen == .settings, let target = scroll.target else { return }
        try? await Task.sleep(for: .milliseconds(250))
        visibleCluster = target
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
        scroll.target = nil
    }

    /// The first row: "Preferences ›" on Settings, "Settings ›" on Preferences.
    private var crossLink: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsLinkRow(SettingsMap.crossLinkTitle(on: screen), detail: SettingsMap.crossLinkDetail(on: screen),
                            action: openOther) { EmptyView() }
        }
        .padding(.horizontal, MGSpace.tileInset)
        .mgSurface(.tile)
    }

    private func clusterIndex(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: MGSpace.s) {
                ForEach(clusters) { cluster in
                    SettingsIndexChip(cluster.label, selected: visibleCluster == cluster.id) {
                        visibleCluster = cluster.id
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(cluster.id, anchor: .top) }
                    }
                }
            }
            .padding(.horizontal, MGSpace.gutter)
        }
        .scrollIndicators(.hidden)
        .frame(height: MGSpace.tapTarget)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kicker)
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text(screen.rawValue)
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsIndexChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.mgColors) private var colors

    init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .mgFont(.kicker)
                .foregroundStyle(selected ? colors.buttonText.color : colors.ink2.color)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Capsule().fill(selected ? colors.buttonFill.color : colors.chip.color))
                .frame(minHeight: MGSpace.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
