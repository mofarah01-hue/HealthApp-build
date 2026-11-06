import SwiftUI
import UIKit
import MGContext
import MGDesign
import MGDomain
import UniformTypeIdentifiers

// WP-23a — the root (UX §3.1): four tabs in this order, Today · Live · Log · Explore (BRIEF default 1); each tab its own
// NavigationStack (pushed screens sit above the content and below the tab bar, which never hides); sheets for Tonight,
// Strap & sync, Pairing, the clock consent and receipts; full-screen covers for Breathe and the HRV check. The day's theme
// (`DayContext.theme`) is applied ABOVE every stack, sheet and cover (BRIEF WP-12 / WP-19 rows), with `\.mgNow`,
// `\.mgSend` and `\.mgQuietHaptics`. Re-tapping the current tab pops to its root, or scrolls to the top when already
// there (`\.mgScrollToTop`). Views get only states and `send`; nothing here touches a service.
//
// WRITTEN, NOT COMPILED.

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// R9f (N4): the notice the user tapped open; shown in full until tapped again (the model's own copy times out after 5 s).
    @State private var heldNotice: String?
    /// r9v (T3): an intent to send once the sheet that asked for it has finished closing (`.sheet(onDismiss:)`).
    @State private var afterSheet: UIIntent?

    init(model: AppModel) {
        self.model = model
    }

    private var colors: ThemeColors { Theme.colors(for: model.theme) }

    var body: some View {
        tabs
            // Wave 2 (Mo: "if stuff is processing I want to know about it"): history download, compute, sync.
            .safeAreaInset(edge: .top, spacing: 0) {
                // T25/T108: not on Today (the failure badge there is T108); an inset, so never over a Back button.
                if !model.workingState.isEmpty, model.tab != .today {
                    RootWorkingLine(state: model.workingState) { model.send(.openPreferences) }
                        .transition(.opacity)
                } else if model.tab == .today, let badge = model.workingBadge {
                    RootWorkingBadge(badge: badge) { model.send(badge.opensStrapSync ? .openStrapSync : .openPreferences) }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.workingState)
            .strapUnlockConfirmSheet(model.services.unlockPresenter)
            .sheet(item: $model.sheet, onDismiss: {
                if let intent = afterSheet { afterSheet = nil; model.send(intent) }
            }) { sheet in
                themed(sheetContent(sheet))
                    // R8e (N1): a receipt tapped inside this sheet opens on top of it; the sheet stays.
                    .sheet(isPresented: nestedReceiptPresented) {
                        if let receipt = model.sheetReceipt {
                            themed(RootReceiptSheet(receipt: receipt).presentationDetents([.medium]))
                        }
                    }
            }
            .fullScreenCover(item: $model.cover, onDismiss: { Task { await model.coverDismissed() } }) { cover in
                themed(coverContent(cover))
            }
            .fileExporter(isPresented: exportPresented, document: model.exportDocument, contentType: .folder,
                          defaultFilename: model.exportDocument?.name) { result in
                model.exportFinished(result)
            }
            .overlay(alignment: .top) {
                if let notice = heldNotice ?? model.notice {
                    RootNotice(text: notice, held: heldNotice != nil) {      // R9f N4: tap = read all and keep it
                        heldNotice = heldNotice == nil ? notice : nil
                    }
                        .padding(.top, 6)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                // r9q: "Workout? Yes / No" while the raw streams are on for a likely workout (above the tab bar)
                if let prompt = model.autoWorkoutPrompt {
                    AutoWorkoutPromptCard(prompt: prompt) { yes in model.send(.autoRaw(.answerWorkout(yes))) }
                        .padding(.horizontal, MGSpace.l)
                        .padding(.bottom, 64)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.autoWorkoutPrompt)
            .animation(.easeOut(duration: 0.25), value: model.notice)
            .animation(.easeOut(duration: 0.25), value: heldNotice)
            .modifier(RootEnvironment(model: model))
            .dismissesKeyboardOnTapOrScroll()   // T9746: tap outside a text field or scroll puts the keyboard away
            .preferredColorScheme(colors.isDark ? .dark : .light)
            .task { await model.start() }
            .onAppear {
                styleTabBar()
                model.noteFirstFrame()      // R7 / T23: launch timing
            }
            .onChange(of: model.theme) { _, _ in styleTabBar() }
            .onChange(of: model.tab) { _, _ in
                model.applyRealtime()
                model.screensChanged()      // R8e: a hidden tab that opens is built from the newest snapshot
            }
            .onChange(of: model.paths) { _, _ in model.screensChanged() }
            .onChange(of: model.sheet) { old, new in
                model.screensChanged()
                // R8e (X4): only sheets that can change state ask the PC for its status and rebuild everything.
                if let old, old != new { Task { await model.sheetDismissed(old) } }
            }
            .onChange(of: model.cover) { _, _ in model.applyRealtime() }
    }

    // MARK: Tabs

    private var tabs: some View {
        TabView(selection: tabSelection) {
            stack(.today) { todayRoot }
                .tabItem { Label { Text(AppTab.today.title) } icon: { RootTabGlyph.sundial } }
                .tag(AppTab.today)
            stack(.live) { liveRoot }
                .tabItem { Label(AppTab.live.title, systemImage: "waveform.path.ecg") }
                .tag(AppTab.live)
            stack(.log) { logRoot }
                .tabItem { Label(AppTab.log.title, systemImage: "plus.circle") }
                .tag(AppTab.log)
            stack(.explore) { exploreRoot }
                .tabItem { Label(AppTab.explore.title, systemImage: "square.grid.2x2") }
                .tag(AppTab.explore)
        }
        .tint(colors.ink.color)
    }

    /// P11: active tab = ink, inactive = mute, a hairline on top (the background is `toolbarBackground` below). The proxy
    /// reaches tab bars created after the call; the theme changes only at phase boundaries.
    private func styleTabBar() {
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(colors.mute.color)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(colors.mute.color)]
        item.selected.iconColor = UIColor(colors.ink.color)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(colors.ink.color)]
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(colors.sheet.color)
        bar.shadowColor = UIColor(colors.rule.color)
        bar.stackedLayoutAppearance = item
        bar.inlineLayoutAppearance = item
        bar.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
    }

    /// Selecting the tab that is already selected = re-tap (UX §3.1): `.scrollToTop` pops the stack, or scrolls to the
    /// top when already at the root (sent as an intent since wave 2, so the action has a sender like every other).
    private var tabSelection: Binding<AppTab> {
        Binding(get: { model.tab }, set: { new in
            if new == model.tab {
                model.send(.scrollToTop(new))
            } else {
                model.tab = new
            }
        })
    }

    private func path(_ t: AppTab) -> Binding<[RootRoute]> {
        Binding(get: { model.paths[t] ?? [] }, set: { new in
            model.paths[t] = new
            model.pathChanged(t)
        })
    }

    private func stack<Root: View>(_ t: AppTab, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: path(t)) {
            root()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RootRoute.self) { route in
                    destination(route)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .environment(\.mgScrollToTop, model.scrollTicks[t] ?? 0)
        .toolbarBackground(colors.sheet.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder private var todayRoot: some View {
        if let s = model.today {
            EquatableScreen(s) { TodayView(state: s, send: model.send) }.equatable()
        } else if let saved = model.launchPreview {
            LaunchPreviewView(preview: saved)       // R7 / T23: the last front page until the real one is built
        } else {
            ScreenSkeleton()
        }
    }

    @ViewBuilder private var liveRoot: some View {
        if let s = model.live {
            EquatableScreen(s) { LiveView(state: s, send: model.send) }.equatable()
        } else {
            ScreenSkeleton()       // R8o (UI-SCRUB-B N5): a light skeleton, not a bare spinner
        }
    }

    @ViewBuilder private var logRoot: some View {
        if let s = model.log {
            EquatableScreen(LogScreenKey(state: s, catalogue: model.logCatalogue)) {
                LogView(state: s, catalogue: model.logCatalogue, send: model.send)
            }.equatable()
        } else {
            ScreenSkeleton()
        }
    }

    @ViewBuilder private var exploreRoot: some View {
        if let s = model.explore {
            EquatableScreen(s) { ExploreView(state: s, send: model.send) }.equatable()
        } else {
            ScreenSkeleton()
        }
    }

    // MARK: Pushed screens

    /// R8e (X1): every pushed screen sits in an `EquatableScreen` keyed by its state, like the tab roots, so the model's
    /// other published changes (the working line, download progress) do not re-run its body. N3/E12: a screen whose state
    /// never arrives gives up after 10 s with a reason and Back.
    private static let giveUp = 10.0

    @ViewBuilder private func destination(_ route: RootRoute) -> some View {
        switch route {
        case .settings:
            if let s = model.settingsState {
                // R8p (S11): the system back button and its edge swipe stay (Settings used to hide the bar, which also
                // switched the swipe off, and drew its own Done).
                EquatableScreen(SettingsScreenKey(state: s, workingDetail: model.workingDetail, testRuns: model.testRuns,
                                                  strap: model.strapSync)) {
                    SettingsView(state: s, send: model.send, testRuns: model.testRuns,
                                 strap: model.strapSync.map { strap in
                                     SettingsStrapEmbed(
                                         state: strap, writeLog: model.strapWriteLog,
                                         deviceSection: AnyView(Whoop4DeviceSection(
                                             coordinator: model.services.whoop4,
                                             choose: { choice in Task { await model.chooseStrapDevice(choice) } },
                                             pair: { model.pairWhoop4() },
                                             stopBuzzing: { Task { await model.stopWhoop4Buzzing() } },
                                             openRaw: { Task { await model.openWhoop4Raw() } })))
                                 })
                }
                .equatable()
                .navigationBarTitleDisplayMode(.inline)
            } else {
                RootLoading(text: "Reading settings…", giveUpAfter: Self.giveUp)
            }
        case .preferences:
            if let s = model.settingsState {
                EquatableScreen(SettingsScreenKey(state: s, workingDetail: model.workingDetail, testRuns: model.testRuns)) {
                    PreferencesView(state: s, send: model.send, workingDetail: model.workingDetail)
                }
                .equatable()
                .navigationBarTitleDisplayMode(.inline)
            } else {
                RootLoading(text: "Reading preferences…", giveUpAfter: Self.giveUp)
            }
        case .night(let day):
            // R8e: the state must be the route's night, or the wake day's night would flash up first (UI-SCRUB-A Night 3).
            if let s = model.night, day == nil || day == s.day {
                EquatableScreen(ThemedScreenKey(state: s, theme: model.theme)) {
                    NightView(state: s, theme: model.theme, send: model.send)
                }.equatable()
            } else {
                RootLoading(text: "Reading that night…", giveUpAfter: Self.giveUp)
            }
        case .workout:
            if let s = model.workoutDetail {
                EquatableScreen(ThemedScreenKey(state: s, theme: model.theme)) {
                    WorkoutDetailView(state: s, theme: model.theme, send: model.send)
                }.equatable()
            } else {
                RootBlank(title: "Workout", reason: "No workout recorded yet. Start one from Live, or the strap's "
                          + "detector will suggest one after it ends.")
            }
        case .metric:
            if let s = model.metricDetail {
                EquatableScreen(s) { MetricDetailView(state: s, send: model.send) }.equatable()
            } else {
                RootLoading(text: "Reading the metric…", giveUpAfter: Self.giveUp)
            }
        case .group:
            if let s = model.group {
                EquatableScreen(s) { GroupView(state: s, send: model.send) }.equatable()
            } else {
                RootBlank(title: "Methods", reason: "No methods stored for this group yet.")
            }
        case .compare:
            if let s = model.compare {
                EquatableScreen(s) { CompareView(state: s, send: model.send) }.equatable()
            } else {
                RootLoading(text: "Reading both metrics…", giveUpAfter: Self.giveUp)
            }
        case .matrix:
            if let s = model.matrix {
                let choices = model.explore.map(ExploreChoices.metrics(from:)) ?? []
                EquatableScreen(MatrixScreenKey(state: s, choices: choices)) {
                    MatrixView(state: s, choices: choices, send: model.send)
                }.equatable()
            } else {
                RootLoading(text: "Reading your metrics…", giveUpAfter: Self.giveUp)
            }
        case .appleHealth:
            EquatableScreen(ObjectIdentifier(model.healthBridge)) {
                AppleHealthScreen(bridge: model.healthBridge, send: model.send)
            }.equatable()
        case .alarms:
            EquatableScreen(ObjectIdentifier(model.alarms)) {
                AlarmsScreen(model: model.alarms, send: model.send)
            }.equatable()
        case .usage:
            EquatableScreen(ObjectIdentifier(model.usage)) {
                UsageScreen(model: model.usage, send: model.send)
            }.equatable()
        case .places:
            EquatableScreen(ObjectIdentifier(model.places)) {
                PlacesScreen(model: model.places, send: model.send)
            }.equatable()
        case .frontPage:
            EquatableScreen(ObjectIdentifier(model.frontPage)) {
                FrontPageSettingsScreen(model: model.frontPage, send: model.send)
            }.equatable()
        case .commandTest:
            EquatableScreen(ObjectIdentifier(model.commandTest)) {
                CommandTestScreen(model: model.commandTest, send: model.send)
            }.equatable()
        case .whoop4Raw:
            EquatableScreen(ObjectIdentifier(model.whoop4Raw)) {
                Whoop4RawScreen(model: model.whoop4Raw, reload: { Task { await model.reloadWhoop4Raw() } },
                                readLed: { Task { await model.readWhoop4LedNow() } })
            }.equatable()
        case .ringLab:
            EquatableScreen(ObjectIdentifier(model.ringLab)) {
                RingLabScreen(model: model.ringLab, send: model.send)
            }.equatable()
        case .screenTime:
            EquatableScreen(ObjectIdentifier(model.screenTime)) {
                ScreenTimeScreen(model: model.screenTime, send: model.send)
            }.equatable()
        case .modelStatus:
            if let s = model.modelStatus {
                EquatableScreen(s) { ModelStatusView(state: s, send: model.send) }.equatable()
            } else {
                RootLoading(text: "Checking every model…", giveUpAfter: Self.giveUp)
            }
        case .ages:
            if let s = model.ages {
                EquatableScreen(s) { InfoScreenView(state: s, send: model.send) }.equatable()
            } else {
                RootLoading(text: "Reading your ages…", giveUpAfter: Self.giveUp)
            }
        case .research:
            if let s = model.research.state {
                EquatableScreen(s) {
                    InfoScreenView(state: s, send: model.send, textIntent: { .research(.startCapture(label: $0)) })
                }.equatable()
            } else {
                RootLoading(text: "Reading the strap records…", giveUpAfter: Self.giveUp)
            }
        }
    }

    // MARK: Sheets and covers

    @ViewBuilder private func sheetContent(_ sheet: RootSheet) -> some View {
        switch sheet {
        case .tonight:
            if let s = model.tonight {
                TonightSheet(state: s, theme: model.theme, send: model.send)
            } else {
                RootLoading(text: "Planning tonight…", giveUpAfter: Self.giveUp)
            }
        case .strapSync:
            if let s = model.strapSync {
                StrapSyncSheet(state: s, writeLog: model.strapWriteLog, send: model.send, close: { model.sheet = nil },
                               closeThen: { afterSheet = $0; model.sheet = nil },
                               deviceSection: AnyView(Whoop4DeviceSection(
                                   coordinator: model.services.whoop4,
                                   choose: { choice in Task { await model.chooseStrapDevice(choice) } },
                                   pair: { model.pairWhoop4() },
                                   stopBuzzing: { Task { await model.stopWhoop4Buzzing() } },
                                   openRaw: { model.sheet = nil; Task { await model.openWhoop4Raw() } })))
            } else {
                RootLoading(text: "Reading the strap…", giveUpAfter: Self.giveUp)
            }
        case .pairing:
            PairingSheet(controller: model.services.pairing, close: { model.sheet = nil })
        case .strapConsent:
            StrapClockConsentSheet(decide: { allow in Task { await model.clockConsentDecided(allow) } })
        case .receipt(let receipt):
            RootReceiptSheet(receipt: receipt)
                .presentationDetents([.medium])
        case .processNow:
            ProcessNowSheet(close: { model.sheet = nil },
                            tryAgain: { Task { await model.processSleepNow() } },
                            sendDetails: { await model.sendProcessDetailsToPC() })
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func coverContent(_ cover: RootCover) -> some View {
        switch cover {
        case .breathe:
            if let s = model.breathe {
                GuidedBreatheView(state: s, theme: model.theme, send: model.send)
            } else {
                RootLoading(text: "Getting the pacer ready…", giveUpAfter: Self.giveUp)
            }
        case .hrvCheck:
            if let s = model.hrvCheck {
                GuidedHRVCheckView(state: s, theme: model.theme, send: model.send)
            } else {
                RootLoading(text: "Getting the check ready…", giveUpAfter: Self.giveUp)
            }
        case .reactionTest:
            ReactionTestView(send: model.send, close: { model.cover = nil })
        case .ecg:
            if let s = model.ecgReading {
                GuidedECGView(state: s, theme: model.theme, send: model.send)
            } else {
                RootLoading(text: "Getting the ECG reading ready…", giveUpAfter: Self.giveUp)
            }
        }
    }

    /// Sheets and covers get the same theme and environment as the tabs (they are separate presentations).
    private func themed<V: View>(_ content: V) -> some View {
        content.modifier(RootEnvironment(model: model))
    }

    private var nestedReceiptPresented: Binding<Bool> {
        Binding(get: { model.sheetReceipt != nil }, set: { shown in
            if !shown, model.sheetReceipt != nil { model.sheetReceipt = nil }
        })
    }

    private var exportPresented: Binding<Bool> {
        Binding(get: { model.exportDocument != nil }, set: { shown in
            if !shown, model.exportDocument != nil { model.exportDocument = nil }
        })
    }
}

/// `.mgTheme` + the screen environment, applied above stacks, sheets and covers.
struct RootEnvironment: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .mgTheme(model.theme)
            .environment(\.mgNow, model.now)
            .environment(\.mgQuietHaptics, model.quietHaptics)
            .environment(\.mgSend, model.send)
            .environment(\.mgPullRefresh, { [model = self.model] in await model.pullRefresh() })
    }
}
