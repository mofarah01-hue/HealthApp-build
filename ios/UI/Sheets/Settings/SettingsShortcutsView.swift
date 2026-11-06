import SwiftUI
import MGContext
import MGDesign

/// R8p (S7): a row of "More screens".
struct SettingsShortcutsRow: View {
    var body: some View {
        NavigationLink {
            SettingsShortcutsView()
        } label: {
            SettingsRow("Shortcuts & automations", detail: "Open Shortcuts and follow the one-time setup for any "
                        + "MG action.", showsChevron: true) { EmptyView() }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsShortcutsView: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.openURL) private var openURL
    @State private var expanded: Set<String> = []

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                SettingsSection("One-time setup", note: "in Apple's Shortcuts app") {
                    ForEach(ShortcutsSettingsPresenter.guides) { guide in
                        guideRow(guide)
                    }
                }
                SettingsSection("After an app update", note: "check once") {
                    Text(ShortcutsSettingsPresenter.updateCheck)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 48)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")          // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Shortcuts")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(ShortcutsSettingsPresenter.installNote)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            MGButton("Open Shortcuts", style: .filled) {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            }
        }
    }

    @ViewBuilder private func guideRow(_ guide: ShortcutAutomationGuide) -> some View {
        let isExpanded = expanded.contains(guide.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded { expanded.remove(guide.id) } else { expanded.insert(guide.id) }
            } label: {
                SettingsRow(guide.name, detail: guide.parameters.map { "Options: " + $0 }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.mute.color)
                        .accessibilityLabel(isExpanded ? "Hide steps" : "Show steps")
                }
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { number, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(number + 1)")
                                .mgFont(.kicker)
                                .foregroundStyle(colors.mute.color)
                                .frame(width: 18, alignment: .trailing)
                            Text(step)
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
            }
        }
    }
}
