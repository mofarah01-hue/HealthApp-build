import SwiftUI
import MGContext
import MGDesign

// R7 / T23: what Today shows from the first frame until the real Today is built (a moment): the front page as it was when
// the app last finished a refresh, as plain text, with the time it was saved. Not interactive; replaced by the real
// Today as soon as it exists.

struct LaunchPreviewView: View {
    let preview: LaunchPreview
    @Environment(\.mgColors) private var colors

    /// R8o (UI-SCRUB-A 0.A-4): saved on an earlier day: the day is named and the numbers are greyed, so it cannot be read as today's.
    private var fromEarlierDay: Bool { !Calendar.current.isDateInToday(preview.savedAt) }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: MGSpace.xs) {
                Text(preview.kicker)
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Text(preview.title)
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .padding(.bottom, MGSpace.l)
                Text(preview.headline)
                    .mgFont(.headline)
                    .foregroundStyle((fromEarlierDay ? colors.ink2 : colors.ink).color)
                if let sentence = preview.sentence {
                    Text(sentence)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                }
                if !preview.items.isEmpty {
                    Text(preview.stripTitle)
                        .mgFont(.kicker)
                        .foregroundStyle(colors.mute.color)
                        .padding(.top, MGSpace.xl)
                    ForEach(Array(preview.items.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.label)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink2.color)
                            Spacer(minLength: MGSpace.s)
                            Text(item.value)
                                .mgFont(.body)
                                .foregroundStyle((fromEarlierDay ? colors.mute : colors.ink).color)
                        }
                    }
                }
                Text(savedLine)
                    .mgFont(.detail)
                    .foregroundStyle(colors.mute.color)
                    .padding(.top, MGSpace.xl)
            }
            .padding(.top, MGSpace.m)
        }
        .accessibilityElement(children: .combine)
    }
}

extension LaunchPreviewView {
    /// "Saved 7:02 AM · updating…", or "Friday's front page, saved 7:02 AM · updating…" when it is from an earlier day.
    fileprivate var savedLine: String {
        let time = MGFormat.time(preview.savedAt, calendar: .current)
        if fromEarlierDay {
            return "\(preview.savedAt.formatted(.dateTime.weekday(.wide)))'s front page, saved \(time) · updating…"
        }
        return "Saved \(time) · updating…"
    }
}

/// R8o (audit §2.7): the first frame while the database opens: the saved front page when there is a fresh one, else a skeleton.
/// It sits before the model exists, so it takes the default theme.
struct StartupView: View {
    let preview: LaunchPreview?

    var body: some View {
        Group {
            if let preview {
                LaunchPreviewView(preview: preview)
            } else {
                ScreenSkeleton()
            }
        }
        .mgTheme(.cream)
        .onAppear { LaunchTimer.reached(.firstFrame) }
    }
}

/// R8o (UI-SCRUB-B N5): what Live, Log and Explore show until their first build: grey blocks the shape of a screen. Static (no
/// animation, no timer), so it costs nothing while the first build runs.
struct ScreenSkeleton: View {
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: MGSpace.m) {
                RoundedRectangle(cornerRadius: 4).fill(colors.rule.color).frame(width: 90, height: 12)
                RoundedRectangle(cornerRadius: 6).fill(colors.rule.color).frame(width: 220, height: 28)
                    .padding(.bottom, MGSpace.m)
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10).fill(colors.rule.color).frame(height: 64)
                }
            }
            .padding(.top, MGSpace.m)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
