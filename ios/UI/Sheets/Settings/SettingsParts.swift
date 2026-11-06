import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Building blocks of the Settings screen. Prefix "Settings" because every file under UI/ compiles into one module.
// Views with private wrapper properties have explicit inits (a synthesized memberwise init would be private).

/// Section head + a run of rows separated by hairlines (the same look as Today's Now list).
struct SettingsSection<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title, note: note)
                .padding(.bottom, MGSpace.s)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, MGSpace.tileInset)
            .mgSurface(.tile)
        }
        .padding(.bottom, MGSpace.section)
    }
}

/// A row: title and detail on the left, anything on the right, a hairline underneath.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let showsChevron: Bool
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, showsChevron: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.showsChevron = showsChevron
        self.trailing = trailing()
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.ink2.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
    }
}

/// A tappable row (opens an editor or another screen): chevron on the right.
struct SettingsLinkRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let enabled: Bool
    let action: () -> Void
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, enabled: Bool = true, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.enabled = enabled
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            SettingsRow(title, detail: detail, showsChevron: true) { trailing }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// A trailing value as text ("07:10", "not set").
struct SettingsValueText: View {
    let text: String
    let muted: Bool

    init(_ text: String, muted: Bool = false) {
        self.text = text
        self.muted = muted
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text)
            .mgFont(.detail)
            .foregroundStyle(muted ? colors.mute.color : colors.ink2.color)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A switch row. `onChange` gets the NEW value; the presenter's state decides what the switch shows next.
struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    let isOn: Bool
    let enabled: Bool
    /// Shown under a disabled switch.
    let reason: String?
    let onChange: (Bool) -> Void

    init(_ title: String, detail: String? = nil, isOn: Bool, enabled: Bool = true, reason: String? = nil,
         onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.enabled = enabled
        self.reason = reason
        self.onChange = onChange
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        OptimisticToggle(isOn: isOn, onChange: onChange) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !enabled, let reason {
                    LogHint(reason)
                }
            }
        }
        .tint(colors.focus.color)
        .disabled(!enabled)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
    }
}

/// "PLACEHOLDER" / "supplement": a small dashed tag, shape and word, never colour alone.
struct SettingsTag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }
    var body: some View {
        TagPill(text: text)
    }
}

/// Weekday names for the "must be up by" rows. 1 = Sunday … 7 = Saturday (Calendar convention, as UIIntent).
enum SettingsWeekday {
    static let names: [Int: String] = [
        1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday", 5: "Thursday", 6: "Friday", 7: "Saturday",
    ]
    static let short: [Int: String] = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
    /// Monday first, as the week reads in the UI.
    static let order: [Int] = [2, 3, 4, 5, 6, 7, 1]
}
