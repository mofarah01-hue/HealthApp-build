import SwiftUI
import MGContext
import MGDesign
#if SCREEN_TIME && canImport(FamilyControls)
import DeviceActivity
import FamilyControls
#endif

// Settings > Screen Time (Mac build, Nov 2026). Built from the app's own parts (MGScreen, SettingsSection / SettingsRow,
// MGCard, Chip, MGButton, the same pulsing placeholder as LoadingBlock): no new visual language. Pure rendering of
// `ScreenTimeState` (ScreenTimePresenter); the only outputs are `UIIntent.screenTime(_:)` and, on the Xcode build, the system
// apps picker and Apple's report view. WRITTEN, NOT COMPILED: the Family Controls parts need the first runner build.

struct SettingsScreenTimeRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Screen Time", detail: "Phone use from iOS Screen Time: thresholds passed in the evening and at night, "
                        + "and today's totals drawn by iOS.",
                        action: { send(.screenTime(.open)) }) { EmptyView() }
    }
}

struct ScreenTimeScreen: View {
    @ObservedObject var model: ScreenTimeModel
    let send: (UIIntent) -> Void

    init(model: ScreenTimeModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        if let s = model.state {
            ScreenTimeView(state: s, model: model, send: send)
        } else {
            ScreenSkeleton()
        }
    }
}

struct ScreenTimeView: View {
    let state: ScreenTimeState
    let model: ScreenTimeModel
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                if let message = state.message {
                    Text(message)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }
                ForEach(state.sections) { section in
                    UsageSectionView(section: section)
                }
                #if SCREEN_TIME && canImport(FamilyControls)
                if state.supported { ScreenTimeControls(controller: model.controller, state: state, send: send) }
                #endif
                if !state.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.actions) { action in
                            MGButton(action.title, style: action.id == "refresh" ? .ghost : .filled) {
                                if let i = action.intent { send(i) }
                            }
                            .disabled(!action.enabled)
                            if !action.enabled, let why = action.disabledReason {
                                Text(why).mgFont(.detail).foregroundStyle(colors.ink2.color)
                            }
                        }
                    }
                    .padding(.top, 16)
                }
                #if SCREEN_TIME && canImport(FamilyControls)
                if state.supported { ScreenTimeReportSection() }
                #endif
            }
            .padding(.bottom, 48)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Screen Time")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

#if SCREEN_TIME && canImport(FamilyControls)

/// The apps picker and the evening threshold, both pre-filled: 60 minutes; the categories iOS will not let an app tick for you,
/// so the page says which to tap.
private struct ScreenTimeControls: View {
    @ObservedObject var controller: ScreenTimeController
    let state: ScreenTimeState
    let send: (UIIntent) -> Void
    @State private var picking = false
    @Environment(\.mgColors) private var colors

    var body: some View {
        SettingsSection("What to watch", note: "your choice stays on this iPhone") {
            SettingsRow("Apps and categories", detail: "In the list, tap Social, Entertainment and Games, then Done. "
                        + "iOS does not let an app tick them for you.") {
                MGButton(controller.selectionSummary == nil ? "Choose" : "Change", style: .ghost) { picking = true }
            }
            SettingsRow("Evening threshold", detail: "The call comes when the picked apps pass this in the evening window.") {
                HStack(spacing: 6) {
                    ForEach(ScreenTimePlan.eveningThresholdChoices, id: \.self) { m in
                        Chip("\(m) min", selected: controller.eveningThreshold == m) {
                            send(.screenTime(.setEveningThreshold(m)))
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .familyActivityPicker(isPresented: $picking, selection: $controller.selection)
    }
}

/// Apple's report view, drawn by the Screen Time report extension. The app cannot read these numbers (iOS keeps them inside the
/// extension), so they are labelled with where they come from. iOS gives no "loaded" signal: the placeholder shows first and
/// fades after a moment, whether or not the report has drawn yet.
private struct ScreenTimeReportSection: View {
    @State private var loaded = false

    private static var today: DateInterval { Calendar.current.dateInterval(of: .day, for: Date()) ?? DateInterval(start: Date(), duration: 86_400) }

    private static var evening: DateInterval {
        let day = today
        let start = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: day.start) ?? day.start
        return DateInterval(start: start, end: day.end)
    }

    var body: some View {
        SettingsSection("Today on this iPhone", note: "drawn by iOS Screen Time; the app cannot copy these numbers") {
            ZStack(alignment: .top) {
                VStack(spacing: MGSpace.m) {
                    DeviceActivityReport(DeviceActivityReport.Context("totals"), filter: DeviceActivityFilter(
                        segment: .daily(during: Self.today), users: .all, devices: .init([.iPhone])))
                        .frame(height: 240)
                    DeviceActivityReport(DeviceActivityReport.Context("evening"), filter: DeviceActivityFilter(
                        segment: .hourly(during: Self.evening), users: .all, devices: .init([.iPhone])))
                        .frame(height: 120)
                }
                if !loaded {
                    ScreenTimeReportSkeleton()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.top, 8)
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) { loaded = true }
        }
    }
}

/// The same calm pulsing blocks as `LoadingBlock`, in the shape of the two report cards.
private struct ScreenTimeReportSkeleton: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        VStack(spacing: MGSpace.m) {
            RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).frame(height: 240)
            RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).frame(height: 120)
        }
        .foregroundStyle(colors.trackPale.color)
        .opacity(reduceMotion ? 0.7 : (bright ? 0.85 : 0.55))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: bright)
        .onAppear { bright = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Screen Time")
    }
}

#endif
