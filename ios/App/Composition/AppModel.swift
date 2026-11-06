import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal
import MGHealth
import MGStore
import MGSync
import UIKit

// WP-23a — the app's one model (ARCHITECTURE §11 WP-23): owns the services, publishes every screen's state by calling
// WP-23b's presenters with one `PresenterSnapshot` (AppModel+Snapshot.swift), and handles every `UIIntent`
// (AppModel+Intents.swift and the area files next to it). Views never touch a service (§4.7).
//
// Refresh rhythm: the whole day on launch, foreground, every minute (the dial hand moves once a minute, UX §1.4), at the
// context's `nextChange`, after every intent and data change; the live part (Live tab, Breathe, HRV check) once a
// second while one of them is on screen.
//
// WRITTEN, NOT COMPILED.

@MainActor
final class AppModel: ObservableObject {
    // MARK: Screen states (WP-23b presenters)

    @Published var today: TodayState?
    @Published var live: LiveState?
    @Published var log: LogState?
    @Published var explore: ExploreState?
    @Published var metricDetail: MetricDetailState?
    @Published var group: GroupState?
    @Published var compare: CompareState?
    @Published var matrix: MatrixState?
    @Published var tonight: TonightState?
    @Published var night: NightState?
    @Published var settingsState: SettingsState?
    @Published var strapSync: StrapSyncState?
    @Published var breathe: BreatheState?
    @Published var hrvCheck: HRVCheckState?
    @Published var workoutDetail: WorkoutDetailState?
    /// Model status page (2026-10-11); built only while it is on a stack.
    @Published var modelStatus: ModelStatusState?
    /// "Your ages" (W10); built only while it is on a stack.
    @Published var ages: InfoScreenState?
    /// Wave 2: the "Working on…" line (history download, compute, sync); empty = hidden.
    @Published var workingState = WorkingState(lines: [])
    /// T149: Settings › Working on (every job, how far, why waiting); shown whether or not the top strip is hidden.
    @Published var workingDetail = WorkingDetailState.empty
    /// T108: the one failure badge on Today (sync broken, history stuck, compute running far too long); nil = nothing wrong.
    @Published var workingBadge: WorkingBadge?
    /// Settings > Tests: the ten newest saved alarm / SpO2 test runs.
    @Published var testRuns = TestRunsState.empty
    /// Strap & sync › write log (data, not state: `StrapSyncSheet(writeLog:)`).
    @Published var strapWriteLog: [StrapWriteEntry] = []
    /// The day's theme (UX §1.1), applied by RootView above every stack, sheet and cover.
    @Published var theme: ThemeName = .cream
    /// Night and Late night: no haptics (UX §1.4).
    @Published var quietHaptics = false
    /// The screen's "now" (`\.mgNow`).
    @Published var now = Date()
    @Published var logCatalogue: LogCatalogue = .standard
    /// One line at the top of the screen for a few seconds: what was refused or failed, and why. Never a modal.
    @Published var notice: String?
    /// R7 / T23: the front page as it was when the app last finished a refresh (a small file); drawn while the real Today
    /// is still being built, and never after it exists. nil = nothing kept, or it is too old.
    @Published var launchPreview: LaunchPreview?

    // MARK: Navigation (UX §3.1)

    @Published var tab: AppTab = .today
    @Published var paths: [AppTab: [RootRoute]] = [:]
    @Published var sheet: RootSheet?
    @Published var cover: RootCover?
    @Published var scrollTicks: [AppTab: Int] = [:]
    @Published var exportDocument: ExportFolderDocument?
    /// R8e (N1): a receipt tapped inside a sheet opens nested in that sheet (the sheet is not replaced).
    @Published var sheetReceipt: Receipt?

    // MARK: Services and the state behind the snapshot

    let services: AppServices
    /// Settings › Apple Health, the Shortcuts bridge (AppModel+AppleHealth.swift); its page observes it directly.
    let healthBridge = HealthBridgeModel()
    /// The alarm page and the alarms' runtime state (App/Alarms; added 2026-10-11).
    let alarms = AlarmsModel()
    let keepUp = HistoryKeepUpModel()      // wave W11: strap history kept current in the background
    /// Settings › Usage: phone and PC storage, background runs, compute (App/Usage; tracker #40, 2026-10-11).
    let usage = UsageModel()
    /// Settings › Command test (App/CommandTest; T87, 2026-10-13).
    let commandTest = CommandTestModel()
    /// Strap & sync › Device / Live › Raw WHOOP 4.0 data: the 4.0's once-a-second history fields (0.6.0.12).
    let whoop4Raw = Whoop4RawModel()
    /// 0.6.0.12: the 5.0 heart-rate broadcast reader (made when its switch is first turned on) and where the live beats come from
    /// when it is not the MG link ("WHOOP 5.0 broadcast", "WHOOP 4.0"; nil = the MG link).
    var hrReader: HRBroadcastReader?
    var liveBeatSource: String?
    /// Settings › Ring lab (App/RingLab; 0.6.0.5).
    let ringLab = RingLabModel()
    /// Settings › Screen Time (App/ScreenTime; Mac build, Nov 2026).
    let screenTime = ScreenTimeModel()
    /// Live › research screens (W10, #91).
    let research = ResearchModel()
    /// Settings › Places and the presence that tags workouts with them (App/Places; tracker #41, 2026-10-11).
    let places = PlacesModel()
    /// Settings › Front page and Today's "Today so far" read (AppModel+FrontPage.swift; trackers #34, #75, 2026-10-11).
    let frontPage = FrontPageModel()
    /// Battery percent + time left for the strap chip (BatteryEstimator), recomputed every 5 min or on a new percent.
    var batteryEstimate: BatteryEstimate?
    var batteryEstimateAt: Date?
    var batteryEstimateFor: String?
    /// T107/T59: when raw optical / ECG / raw motion / offload were on, for the battery estimate (kv `featureLogKey`).
    var featureLog = FeatureLogRecorder()
    static let featureLogKey = "app.battery_feature_log"
    var featureLogSavedAt: Date?
    /// T9981: the extra %/h per feature learned from featureLog beside the battery readings (kv `batteryLearnedKey`).
    var batteryLearned: BatteryLearnedRates?
    static let batteryLearnedKey = "app.battery_learned_rates"
    var settings = AppSettings()
    var testRunLog = TestRunLog()
    var ledger = PeekLedger()
    var sessions = LiveSessions()
    var profile = Profile()
    /// P9745: the last PC profile fetched (GET /v1/profile); `effectiveProfile` = Me profile + this, for every model.
    var pcProfile: PCProfileSnapshot?
    var effectiveProfile: Profile {
        EffectiveProfile.merged(phone: profile, pc: pcProfile, today: LocalDay(date: clock.now, calendar: calendar))
    }
    var installSalt: Data?

    var strapLinkState: StrapLinkState = .idle
    var strapInfo: StrapInfo?
    var lastWhoop4OpticalAt: Date?         // WHOOP4-WIRE 6: gap between the 4.0's optical frames (AppModel+Whoop4Raw)
    /// T10004: the pairing is read from the Keychain at once (no await), so a paired phone never starts as "PC not set up";
    /// the last sync time arrives with the first `refreshStatus()`, and until then the chip says "PC connecting…".
    var syncStatus: SyncStatus = AppModel.initialSyncStatus()
    /// T10004: false until the first real sync status is in (or 8 s have passed): `PresenterUI.settling`.
    var settling = true
    /// T9999: newest stored heart-rate second (read at most every 20 s) for the strap sheet's "Last record".
    var storedRecordCache: (at: Date?, readAt: Date)?
    /// T110: the off-wrist flag lives in the tracker (strap events, live beats and a relaunch all move it); `offWristSince`
    /// stays the read-only view every screen already uses.
    var wrist = OffWristTracker()
    var offWristSince: Date? { wrist.offSince }
    var wearLocation: WearLocation?
    var charging: Bool?
    var liveBuffer = LiveBeatBuffer()
    /// W10 #94: ALG-054's hour-by-hour baseline for the Live tile, read once a day from the stored 5-min series.
    var autonomicBaseline: (day: LocalDay, baseline: ALG054.Baseline, samples: Int)?
    var autonomicBaselineLoading = false
    /// When the Live tab's charts were last filled from the store (#35, AppModel+LiveSeed.swift).
    var liveSeededAt: Date?
    var smartWake: SmartWakeController?
    var lastSmartWakeRequest: SmartWakeRequest?
    var lastSmartWakePhase: DayPhase?
    var smartWakeWatching = false
    var healthState: HealthAuthState?
    var healthLastRead: Date?
    /// The newest stored strap settings snapshot (117/118/128; added 2026-10-11), for Strap & sync.
    var flagSnapshot: StrapFlagSnapshot?
    /// Raw optical as the link reports it, and whether the app is in the foreground (raw optical runs only then).
    var rawOpticalStatus = RawOpticalStatus()
    /// r8 (2026-10-17): the newest R20 record index handed to the Live PPG feed. Raw optical is now published at most once a
    /// second (r8i), so one publish can carry several new records; every one newer than this is fed, in order.
    var lastFedR20Index: Int64 = -1
    /// R8 brain: when the last headless background pass ran (background relaunch only; throttle 5 min).
    var lastHeadlessPass: Date?
    /// T10005: the Live pulse rate for the newest raw-optical records (AppModel+Snapshot `livePulseOnce`).
    var livePulseMemo: (key: LivePulseMemoKey, value: OpticalPulse.Live)?
    var appActive = true
    /// Wave 4 (#65): the nights-only schedule's decision now, and the measured battery cost (re-read every 30 min).
    var rawOpticalDecision: RawOpticalNight.Decision?
    var rawOpticalCost: RawOpticalCost.Estimate?
    var rawOpticalCostAt: Date?
    /// Wave 4 (#77): an experimental SpO₂ spot measurement holds raw optical on until this time.
    var spo2SpotUntil: Date?
    /// R9f: the run token of the spot reading in progress. Cancel clears it; the waiting run checks it after each wait and
    /// stops quietly when it no longer matches (so a cancelled run never touches a newer one).
    var spo2SpotRun: UUID?
    /// T124: a "still wrist" window holds raw optical on until this time; the last "may run" sent to the link.
    var rawOpticalStillUntil: Date?
    var rawOpticalAllowedLast: Bool?

    var breatheSession: BreatheSession?
    var hrvSession: HRVCheckSession?
    /// The MG ECG reading and raw motion R21 (wave W8, 2026-10-11; AppModel+EcgMotion.swift).
    @Published var ecgReading: EcgReadingState?
    var ecgSession: EcgSession?
    var ecgStatus = EcgStatus()
    var rawMotionStatus = RawMotionStatus()
    /// r9q: the automatic raw streams (workout detector state, the heart-rate minutes, a running burst) and the open question.
    var autoRaw = AutoRawRuntime()
    @Published var autoWorkoutPrompt: AutoWorkoutPrompt?
    var motionTrace = MotionTraceBuffer()
    var ecgMotionTasks: [Task<Void, Never>] = []
    /// Live › Research › "Test: read history without deleting" (wave W12b; AppModel+HistoryReadTest.swift).
    var historyReadTestRunning = false
    var historyReadTestLines: [String] = []

    // State-driven expansion (WP-07 rule: never local view state).
    var openRows: Set<String> = []
    var expandedGroups: Set<String> = []
    var showDroppedGroups: Set<String> = []
    var napPeekStep = 1
    var workoutPeekStep = 1
    /// The question id a step-2 belongs to (a new question starts at step 1).
    var stepQuestionId: [PeekKindKey: String] = [:]

    // Explore.
    var exploreQuery = ""
    var metricView: MetricViewMode = .number
    var detailKey: String?
    var detailVariant: String?
    var groupId: String?
    var compareFirst: String?
    var compareSecond: String?
    var compareLag = 0

    // Night / workout detail requests.
    var nightDay: LocalDay?
    var workoutRequested = false
    var workoutId: UUID?

    /// Events logged this session, newest last (`.undoLastLog` removes the newest — soft remove).
    var lastLogged: [UUID] = []
    var lastDoubleTap: (ts: Int64, at: Date)?
    var systemIsDark = false
    var realtimeOn = false

    /// Night for a day other than the current wake day (`.openNight(day)`).
    var nightOverride: (day: LocalDay, metrics: [Metric], series: [Series])?
    /// Median of the last 14 nights' RMSSD, for the HRV check's comparison line; nil = no baseline yet.
    var nightMedianRmssd: Double?
    /// The last MatrixPipeline result, keyed by its keys / period / day (recomputed when the Matrix opens or they change).
    var matrixCache: (key: String, cells: [[CorrelationInput]])?
    /// Model status: newest value per "metric|variant" (60 days, imports included), read at most every 15 min.
    var modelOutputsCache: (at: Date, sample: Bool, outputs: [String: ModelOutput])?
    /// Wave 2 (AppModel+Outputs.swift): every source's newest value and the PC results, cached; today's non-metric
    /// outputs from the last compute; the alerts raised now; what is running.
    var outputsCache: (key: String, at: Date, latest: [String: [DatedMetric]], pc: [LabResult], unreadable: [String])?
    /// Tracker #7: older periods fetched from the PC, in memory only (AppModel+PCHistory.swift).
    let pcHistoryCenter = PCHistoryCenter()
    var lastComputeAt: Date?
    var lastDayExtras: DayExtrasInput?
    var currentAlerts: [AlertInfo] = []
    var working = WorkingInput.idle

    var lastSnapshot: PresenterSnapshot?
    var lastContext: DayContext?
    var lastInputs: ContextInputs?

    private var started = false
    /// R8o (audit §2.7): this run was started by a background relaunch (Bluetooth restore, BGTask): only the strap link, ingest,
    /// the sync cadence, alarms and the history keep-up are running. No screens are built until the app is opened.
    private var backgroundOnly = false
    private var backgroundStartDone = false
    /// The app was opened while the background start was still running: the foreground part follows it.
    private var upgradeWanted = false
    private var lifecycleStarted = false
    /// R7 / T23: the next refresh is the first one of this launch (Today only).
    private var launchLight = true
    private var lastLaunchPreviewSaved: LaunchPreview?
    /// Settings are read and the first refresh is done (scene-phase triggers wait for this).
    private var ready = false
    private var refreshing = false
    private var refreshAgain = false
    /// R8e: a cheap pass (same snapshot, new view state) is wanted; runs after the full pass that is in flight.
    private var rerenderPending = false
    /// R8e: false while `lastSnapshot` is the light launch pass (a rerender then would build screens from half a snapshot).
    private var lastWasLight = true
    /// R8e (§0.C-2): which hidden screens were built from which snapshot generation (a screen built from an older one is
    /// stale when it opens), and whether every screen has been built once (the first full pass).
    var snapshotGen = 0
    var gatedBuiltGen: [String: Int] = [:]
    var gatedBuiltOnce = false
    private var tickers: [Task<Void, Never>] = []
    /// T9819: alive / killed log and the debug ping to the PC (LifecycleRecorder.swift).
    private(set) lazy var lifecycle = LifecycleRecorder(clock: services.clock)
    /// T10012: the remote debug channel's poll loop (AppModel+RemoteDebug.swift).
    private(set) lazy var remoteDebug = RemoteDebugRunner()
    /// Live pace (R-094 choppy / freezing Live, 2026-10-14): when the Live tab was last rebuilt (uptime s), and what the
    /// stall watch measured since it last wrote a line to the strap log.
    var liveRefreshedAt: TimeInterval = 0
    /// T9988: uptime of the last beat that asked the sync coordinator whether a sync is due (every 5 min at most).
    var syncCadenceBeatAt: TimeInterval = -1000
    var livePace = LivePace()
    /// P9729 (job 12): the last ALG-144 cleaned-wave result for Live, the newest record it used, and whether a run is
    /// going (AppModel+LiveClean.swift).
    var liveClean = LiveCleanState()
    private var noticeTask: Task<Void, Never>?
    private var nextChangeTask: Task<Void, Never>?
    var lastStrapDownloading = false
    /// T23: at most one full screen rebuild per 5 s for the progress ticks of a running history download.
    var progressRefreshGate = ProgressRefreshGate(minInterval: 5)
    /// This app's intents drain is running (widget writer rule 2: never publish inside it).
    var intentsDraining = false
    var widgetPublishWanted = false
    var widgetProblemShown = false

    var calendar: Calendar { services.calendar }
    var clock: any MGDomain.Clock { services.clock }
    var isSample: Bool { settings.sampleData }
    var source: any SnapshotReading { isSample ? services.sampleSource : services.storeSource }

    init(services: AppServices) {
        self.services = services
        launchPreview = LaunchPreviewFile.load(now: services.clock.now)
        services.link.model = self
        wireStrap()
        wirePlaces()           // early: iOS may relaunch the app in the background with a region event
    }

    // MARK: Lifecycle

    /// From the app holder at launch (`background`: iOS relaunched the app with no screen, by Bluetooth restore or a BGTask), and
    /// again from RootView's `.task`. R8o (audit §2.7, T23): a background relaunch starts only the strap link, ingest, the sync
    /// cadence, alarms and the history keep-up (`startBackground`); the first call from RootView after that does the rest
    /// (`startForeground`). A second call in the same mode does nothing.
    func start(background: Bool = false) async {
        if started {
            if backgroundOnly, !background {
                if backgroundStartDone {
                    backgroundOnly = false
                    await startForeground(resuming: true)
                } else {
                    upgradeWanted = true       // the background start is still running; it hands over when it ends
                }
            }
            return
        }
        started = true
        backgroundOnly = background
        // Wave W11: start() also runs on a background relaunch, where no scene reports a phase: begin from the real state,
        // so foreground-only streams (raw optical / motion while the app is open) don't start unseen.
        appActive = !background && UIApplication.shared.applicationState != .background
        Task { [weak self] in        // never stuck on "connecting…" if the first status read is slow
            try? await Task.sleep(for: .seconds(8))
            self?.settling = false
        }
        await loadStored()
        applyInputDevice()      // 0.6.0.3 Ring live: connect the ring when the setting is Auto or Ring
        applyHRRead()           // 0.6.0.12: the 5.0 heart-rate broadcast reader, when its switch is on
        if background {
            await startBackground()
            backgroundStartDone = true
            if upgradeWanted {
                backgroundOnly = false
                await startForeground(resuming: true)
            }
            return
        }
        await startForeground(resuming: false)
    }

    /// R8o: BLE + ingest and what the background tasks need. No snapshot, no screens, no launch compute, no Health observers,
    /// no tickers (a refresh asked for meanwhile is dropped in `refresh`; the foreground start builds the first one).
    private func startBackground() async {
        if StrapCoordinator.wasPaired || Whoop4Coordinator.wasPaired { startStrapLink() }
        await services.syncCoordinator.start()     // network watcher + the hourly cadence (the BG sync task's partner)
        await services.compute.noteLaunch()        // T9737: log the launch, find a run the last process never finished
        startLifecycleRecording()
        await startAlarms()                        // strap alarms and timers must survive a relaunch at night
        await startHistoryKeepUp()                 // wave W11: history every 15 min while connected, also in the background
        ComputeLog.shared.append(.note, "launch: background relaunch started (strap link and ingest only) "
                                 + "\(LaunchTimer.sinceLaunch()) ms after launch", at: clock.now)
    }

    /// The part of start-up that builds screens and does the foreground work. `resuming`: the background part already ran
    /// (settings loaded, strap link, sync cadence, alarms, keep-up), so those are not repeated.
    private func startForeground(resuming: Bool) async {
        if resuming {
            appActive = UIApplication.shared.applicationState != .background
            applyRawOptical()      // the switches as they are now, app open
            applyRawMotion()
        }
        // V3 (2026-10-15): Today from what is stored, before any sync / strap / health work. Compute never gates it.
        // R7 / T23: this first pass is the light one (Today only, no Model status read); the full pass comes below.
        await refresh()
        // The strap link starts right after the first frame, so live data is not behind the sync / health set-up below.
        if !resuming, StrapCoordinator.wasPaired || Whoop4Coordinator.wasPaired { startStrapLink() }
        systemIsDark = UIScreen.main.traitCollection.userInterfaceStyle == .dark
        await services.compute.startHourly()
        // R7 / T23: let the first frame draw before the rest of the start-up work; each step below was at once.
        try? await Task.sleep(for: .milliseconds(250))
        // 0.6.0.7: the HealthKit observers are registered at every launch in MGApp.init (HealthObserverLaunch), not here.
        await services.syncCoordinator.start()
        await services.nightSounds.start()
        // T9818: phone-use sessions (unlock to lock) as screen_time events; an estimate, only while the process runs.
        let phoneUseStore = services.store
        PhoneUseLog.start(calendar: calendar) { s in _ = try await phoneUseStore.upsertEvent(PhoneUseSessions.event(s)) }
        await ingestScreenTime()      // Mac build: thresholds the Screen Time extension wrote to the App Group while we were away
        if let health = services.health { healthState = await health.authState() }
        syncStatus = await services.sync.refreshStatus()
        settling = false
        await drainIntents()
        await refresh()
        if !isSample {
            Task { [weak self] in
                guard let self else { return }
                // R7 / T23: the sync, the Health read and the profile pull wait until the screens above are drawn.
                try? await Task.sleep(for: .seconds(1.5))
                _ = await self.services.syncCoordinator.appDidBecomeActive()
                self.syncStatus = await self.services.sync.refreshStatus()
                await self.readHealthIfAllowed()
                await self.autoFillProfileFromPC()   // T27: profile from Apple Health via the PC, no tap
                await self.refresh()
            }
        }
        ready = true
        startLifecycleRecording()
        remoteDebug.start(model: self)   // T10012: the long poll for debug commands from the PC (foreground only)
        if !resuming { await services.compute.noteLaunch() }      // T9737: log the launch, find a run the last process never finished, new build?
        // V3: the launch compute runs in the background (today first, older days only if changed); the tickers, alarms and
        // history keep-up below no longer wait for it. Its end is logged with the time since launch.
        // R8o: it is not "user-waiting" (PipelineWiring), so it runs under the normal CPU governor, after the screens.
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))     // R7 / T23: after the full screens above are drawn
            let r = await self.services.compute.runLaunch()
            LaunchTimer.reached(.computeDone)
            ComputeLog.shared.append(.note, "launch: compute (today) done \(LaunchTimer.sinceLaunch()) ms after launch: \(r.line)",
                                     at: self.clock.now)
            ComputeLog.shared.append(.note, "launch timing: \(LaunchTimer.summary())", at: self.clock.now)
        }
        startTickers()
        watchNightSounds()
        // R7 / T23: alarms, the 15-minute history keep-up and the catalogue file are not needed for the first screens.
        try? await Task.sleep(for: .milliseconds(500))
        if !resuming {
            await startAlarms()              // App/Alarms: strap alarms, iPhone backstops, calendar buzz
            await startHistoryKeepUp()       // wave W11: history every 15 min while connected, also in the background
        }
        writeIntentsCatalogue()
    }

    /// The alive / killed log, battery and the debug ping (T9819): once per process, from either start.
    private func startLifecycleRecording() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        lifecycle.snapshot = { [weak self] in
            guard let self else { return (nil, nil, nil, nil) }
            let up: Bool? = { if case .ready = self.services.strap.link?.state { return true }; return self.services.strap.link == nil ? nil : false }()
            return (up, self.liveBuffer.lastBeatAt, self.syncStatus.lastSynced, self.syncStatus.unsyncedDays)
        }
        lifecycle.extras = { [weak self] in self?.statusExtras() ?? StatusExtras() }      // T10010
        lifecycle.onMemoryWarning = { [weak self] in self?.handleMemoryWarning() }        // T10009
        lifecycle.onLaunch = { [weak self] launch in self?.gapNotice(launch) }            // T9992 (r9d)
        lifecycle.onPendingCommands = { [weak self] _ in      // T10012: the ping's answer said commands are waiting
            guard let self else { return }
            self.remoteDebug.nudge(model: self)
        }
        lifecycle.start()                // T9819: how the last run ended, heartbeat, battery, ping
    }

    /// R8o: the launch stages that happen before the model exists, for the compute log (Settings > Usage).
    func logLaunchStages(background: Bool) {
        ComputeLog.shared.append(.note, "launch: \(background ? "background relaunch" : "foreground launch"): "
                                 + LaunchTimer.summary(), at: clock.now)
    }

    /// Scene phase (MGApp): foreground triggers of §5.7, night sounds' foreground rule, questions as notifications
    /// only while the app is closed (UX §5).
    func scenePhaseChanged(active: Bool) async {
        // The first activation arrives before `start()` has read the settings: SAMPLE mode must be known before any
        // sync can run, so the launch path does its own foreground sync.
        guard ready else { return }
        // T9819 #4: foreground restart work (strap re-read, sync, health, refresh) runs only on a real background ->
        // active step. A repeated `.active` (inactive -> active after the control centre, a duplicate first callback)
        // changes nothing and must not re-run it; the background half is likewise once per step.
        let becameActive = active && !appActive
        let wentBackground = !active && appActive
        appActive = active
        lifecycle.phaseChanged(active ? "active" : "background")
        // P9821: a live ECG cannot be trusted to finish while suspended (a once-a-second refresh does not run, and the
        // session lives in memory): leaving the screen ends it now and saves what was recorded; coming back checks the clock.
        if !active, ecgSession?.phase == .recording { Task { [weak self] in await self?.finishECG(reason: "app left the screen") } }
        if active { advanceEcg() }
        Task { [weak self] in await self?.historyKeepUpTick(force: true) }   // wave W11: keep-awake on / off at once
        applyRawOptical()      // T9984: raw optical stays as the switch says (nights-only mode excepted), app open or not
        applyRawMotion()       // T9984: likewise raw motion; a switch that is on keeps live HR on (applyRealtime)
        if becameActive {
            systemIsDark = UIScreen.main.traitCollection.userInterfaceStyle == .dark
            remoteDebug.nudge(model: self)   // T10012: a long poll from before iOS suspended the app is dead; poll afresh
            WatchReceiver.shared.uploadInbox()   // 0.6.0.10: Watch recordings waiting on the phone go to the PC
            Task { [weak self] in await self?.ingestScreenTime() }      // Mac build: Screen Time thresholds written while closed
            wakeStrap("foreground")      // T141 + T9994: re-read the radio, reconnect if the strap is wanted and the link is down
            if liveOnScreen { seedLive() }   // #35: fill what the strap sent while the app was away
            placesBecameActive()             // #41: which saved place Mo is at now (region state, no GPS run)
            lastSmartWakeRequest = nil      // WP-11: re-plan on foreground
            TimersController.shared.start()                       // T153: timers (idempotent), and catch up now
            Task { await TimersController.shared.retryStrapArms(); await TimersController.shared.tick() }
            await services.compute.request(.foreground)   // debounced (3 s) and coalesced like every other request
            await services.nightSounds.setAppActive(true)
            await drainIntents()
            await refresh()
            await appleHealthBecameActive()  // Shortcuts bridge: no-reply check, waiting auto-send and imports
            Task { [weak self] in
                guard let self else { return }
                if !self.isSample { _ = await self.services.syncCoordinator.appDidBecomeActive() }
                self.syncStatus = await self.services.sync.refreshStatus()
                await self.readHealthIfAllowed()
                await self.autoFillProfileFromPC()   // T27
                await self.refresh()
            }
        } else if wentBackground {
            await services.nightSounds.setAppActive(false)
            await services.syncCoordinator.appDidEnterBackground()
            await offerQuestionsAsNotifications()
            await saveState()
            await services.store.checkpointTruncate()      // T10007 / audit 3.1: fold the write-ahead log back into the database file
        }
    }

    /// `mgapp://pair?…` (PairingSheet comment, WP-13): present the sheet and hand the link to the controller.
    /// `healthapp://shortcut/…` (Shortcut callbacks) and `healthapp://import?data=…`: AppModel+AppleHealth.swift.
    func handle(url: URL) {
        if url.scheme?.lowercased() == ShortcutLink.scheme {
            handleHealthAppURL(url)
            return
        }
        guard url.scheme?.lowercased() == "mgapp" else { return }
        if url.host?.lowercased() == "pair" {
            sheet = .pairing
            services.pairing.handle(url: url)
        } else if url.host?.lowercased() == "buzz" {          // T53: `mgapp://buzz?app=personal-os&person=…`
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let app = q.first { $0.name == "app" }?.value ?? "personal-os"
            let person = q.first { $0.name == "person" }?.value
            Task { await buzzForNotification(source: app, person: person) }
        }
    }

    /// A tap on a notification or one of its buttons (WP-24 NotifyResponseMap).
    func handle(notification response: NotifyResponse) async {
        switch response {
        case .intent(let intent):
            send(intent)
        case .smartWake(let action):
            switch action {
            case .stop: await smartWake?.stop()
            case .snooze(let minutes): await smartWake?.snooze(minutes: minutes)
            case .opened: tab = .today
            }
        case .medication(let name, let scheduleId, let taken):
            if taken {
                send(.quickLog(.medication(name: name)))
            } else {
                await logMedicationSkipped(name: name, scheduleId: scheduleId)
            }
        case .autoWorkout(let yes):
            await answerAutoWorkout(yes)       // r9q: the "Workout?" notification buttons
        case .none(let why):
            services.strap.noteExternal("notification: \(why)")
        }
        await refresh()
    }

    /// After a compute: WP-22's workout / nap suggestions become questions (UX §5), then every screen is rebuilt.
    func computeFinished(_ report: ComputeReport) async {
        if report.ran { lastComputeAt = clock.now }
        if let x = report.dayExtras { lastDayExtras = x }
        if !report.suggestedWorkouts.isEmpty || !report.suggestedNaps.isEmpty {
            ledger.merge(workouts: report.suggestedWorkouts, naps: report.suggestedNaps, now: clock.now)
            await saveState()
        }
        await refresh()
        await appleHealthAfterCompute(report)   // Settings › Apple Health › send automatically (when on)
    }

    // MARK: Notices

    func showNotice(_ text: String) {
        NoticeLog.shared.add(text)      // R9f (N4): the last five stay readable in Settings › Usage › Recent messages
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Refresh

    /// Rebuilds every screen from one snapshot. Calls that arrive while one runs are folded into one more run.
    func refresh() async {
        // R8o: a background relaunch builds no screens; the foreground start does. The side effects that keep the night
        // working (smart wake, night sounds, alerts, quiet hours, the wake chain, Health on wake) still run, headless.
        if backgroundOnly { await headlessPass(); return }
        refreshAgain = true
        await drainPasses()
    }

    /// R8e: the same screens from the snapshot already in hand with the view state (open rows, expanded groups) as it is now.
    /// No database reads. Used for pure display intents; folded into any pass that is running.
    func rerender() async {
        guard !backgroundOnly else { return }
        rerenderPending = true
        await drainPasses()
    }

    /// One worker for both kinds of pass, so a cheap pass can never apply an older result over a newer full one.
    private func drainPasses() async {
        if refreshing { return }
        refreshing = true
        while refreshAgain || rerenderPending {
            if refreshAgain {
                refreshAgain = false
                rerenderPending = false          // a full pass covers the cheap one
                await refreshOnce()
            } else {
                rerenderPending = false
                await rerenderOnce()
            }
        }
        refreshing = false
    }

    private func rerenderOnce() async {
        guard !launchLight, !lastWasLight, var s = lastSnapshot else { return }
        s.ui = presenterUI()
        snapshotGen += 1
        lastSnapshot = s
        await present(s)
    }

    /// R8e: the open set changed (a tab, a pushed screen, a sheet). A hidden screen that opens is built from the newest
    /// snapshot; Explore and Settings also need inputs the snapshot only reads while they are open, so they get a full pass.
    func screensChanged() {
        guard !backgroundOnly, !launchLight, !lastWasLight, lastSnapshot != nil else { return }
        let stale = openGatedScreens().filter { gatedBuiltGen[$0] != snapshotGen }
        guard !stale.isEmpty else { return }
        let needsInputs = !stale.isDisjoint(with: ["explore", "settings", "matrix"])
        if refreshing {
            if stale.contains("explore") && !matrixOnScreen { refreshAgain = true } else { rerenderPending = true }
            return
        }
        Task { [weak self] in
            if needsInputs { await self?.refresh() } else { await self?.rerender() }
        }
    }

    /// The screens that are built only while open (Tonight and the wake-day Night are always built: Today's dial reads them).
    func openGatedScreens() -> Set<String> {
        var open = Set<String>()
        if tab == .log { open.insert("log") }
        if tab == .explore || matrixOnScreen { open.insert("explore") }
        if matrixOnScreen { open.insert("matrix") }
        if settingsOnScreen { open.insert("settings") }
        if sheet == .strapSync { open.insert("strapSync") }
        return open
    }

    /// R8 brain (2026-10-17): the background-relaunch pass. Builds the snapshot (no presenters, no screens) and runs only
    /// the side effects a sleeping night needs: smart wake arming (updateSmartWake), night sounds, alerts, quiet hours,
    /// the wake chain (compute.noteWake) and the Health pull on wake. At most once per 5 minutes (low resource use).
    private func headlessPass() async {
        let t = clock.now
        if let last = lastHeadlessPass, t.timeIntervalSince(last) < 300 { return }
        lastHeadlessPass = t
        do {
            let s = try await buildSnapshot(now: t, light: false)
            lastContext = s.context
            lastInputs = s.inputs
            await postAlertsAndReminders(s)
            scheduleNextChange(s.context.nextChange)
            await updateSmartWake(s)
            await updateNightSoundsPlan(s)
            await services.notifyCenter.setQuietContext(
                window: NotifyQuietWindow.placeholder(anchors: s.context.anchors, policy: services.notifyCenter.policy,
                                                      calendar: calendar),
                wokeAt: s.inputs.detectedWake,
                extraQuiet: sessions.nap.map { [DateInterval(start: $0.start, duration: Double($0.plannedMinutes) * 60)] } ?? [])
            await services.compute.noteWake(s.inputs.detectedWake)
            if let wake = s.inputs.detectedWake, let auto = services.healthAuto, !isSample, await auto.noteWake(wake) {
                Task { [weak self] in await self?.runHealthAuto() }
            }
            ComputeLog.shared.append(.note, "background pass: smart wake, alerts and wake chain checked (no screens)", at: t)
        } catch {
            ComputeLog.shared.append(.note, "background pass: couldn't read the data: \(error)", at: t)
        }
    }

    private func refreshOnce() async {
        // R7 / T23: the published `now` moves once a minute (it is a @Published: every assignment redraws every screen
        // watching the model, and this ran on every refresh). The snapshot below is built at the exact time.
        let t = clock.now
        if MinuteGate.changed(from: now, to: t) { now = t }
        await pushLive()
        // R7 / T23: the very first pass is the light one: Today (and the Live tab's state) only. The pass that follows
        // builds the rest. Anything that asks for a refresh meanwhile is folded into that second pass.
        let light = launchLight
        launchLight = false
        do {
            let s = try await buildSnapshot(now: t, light: light)
            lastSnapshot = s
            lastWasLight = light
            snapshotGen += 1
            lastContext = s.context
            lastInputs = s.inputs
            let busy = await present(s, light: light)
            livePace.noteFull(busy)
            publishWorking()
            if light {
                noteTodayBuilt()               // the full pass follows from `start()` (and from any refresh asked meanwhile)
                return
            }
            saveLaunchPreview()
            await postAlertsAndReminders(s)
            housekeeping(s)
            await rawOpticalNightHousekeeping()      // wave 4 (#65): nights log, battery cost, schedule check
            scheduleNextChange(s.context.nextChange)
            await updateSmartWake(s)
            await updateNightSoundsPlan(s)
            await services.notifyCenter.setQuietContext(
                window: NotifyQuietWindow.placeholder(anchors: s.context.anchors, policy: services.notifyCenter.policy,
                                                      calendar: calendar),
                wokeAt: s.inputs.detectedWake,
                extraQuiet: sessions.nap.map { [DateInterval(start: $0.start, duration: Double($0.plannedMinutes) * 60)] } ?? [])
            await services.compute.noteWake(s.inputs.detectedWake)
            if let wake = s.inputs.detectedWake, let auto = services.healthAuto, !isSample, await auto.noteWake(wake) {
                Task { [weak self] in await self?.runHealthAuto() }     // V3: the night ended: pull sleep, SpO2 ... now
            }
        } catch {
            showNotice("Couldn't read your data: \(error)")
        }
        // R-094: assigned only when it changed — a @Published reassignment redraws every screen watching the model.
        setIfChanged(\.strapWriteLog, (try? await source.strapWrites(limit: 200)) ?? [])
    }

    /// R7 / T23: Today is on screen from stored values: logs the time since launch (first number of the launch timing line)
    /// and keeps this front page for the next launch.
    private func noteTodayBuilt() {
        if let ms = LaunchTimer.reached(.todayBuilt) {
            ComputeLog.shared.append(.note, "launch: Today built from stored values \(ms) ms after launch", at: clock.now)
        }
    }

    /// RootView's first appearance: the first frame (the saved front page, or the loading block) is on screen.
    func noteFirstFrame() {
        if let ms = LaunchTimer.reached(.firstFrame) {
            ComputeLog.shared.append(.note, "launch: first frame \(ms) ms after launch\(launchPreview == nil ? "" : " (saved front page)")",
                                     at: clock.now)
        }
    }

    /// Keeps the front page for the next launch: written only when its text changed, and not in SAMPLE mode.
    private func saveLaunchPreview() {
        guard !isSample, let t = today, let p = LaunchPreview(from: t, savedAt: clock.now) else { return }
        var same = p
        same.savedAt = lastLaunchPreviewSaved?.savedAt ?? p.savedAt
        // Unchanged text: no write, unless the saved copy is over an hour old (so it stays "fresh" for the next launch).
        if let last = lastLaunchPreviewSaved, last == same, p.savedAt.timeIntervalSince(last.savedAt) < 3600 { return }
        lastLaunchPreviewSaved = p
        LaunchPreviewFile.save(p)
    }

    /// The light, once-a-second part: Live tab, Breathe, HRV check (and the guided flows' clocks).
    func refreshLive() {
        let began = ProcessInfo.processInfo.systemUptime
        liveRefreshedAt = began
        defer { livePace.noteLive(ProcessInfo.processInfo.systemUptime - began) }
        // T23: the published `now` (every tab reads it) moves once a minute; this tick's own clock is `t`.
        let t = clock.now
        if MinuteGate.changed(from: now, to: t) { now = t }
        advanceGuidedFlows()
        guard var s = lastSnapshot else { return }
        s.now = t
        s.live = liveInput()
        s.liveHRTrace = liveHRTrace()
        s.liveBackfill = liveBackfillPlan()     // wave W11
        s.breathe = breatheInput()
        s.hrvCheck = hrvCheckInput()
        s.strapSync.ecgMotion = ecgMotionInfo()   // wave W8: the raw-motion trace moves every second
        lastSnapshot = s
        presentLive(s)
        advanceEcg()
        presentEcgReading()
    }

    /// The live half of the context inputs → the data source's box.
    func pushLive() async {
        await updateBatteryEstimate()
        let lastRecord = await lastRecordAt()       // T9999
        let status = StrapStatus(link: StrapCoordinator.linkStatus(strapLinkState, paired: StrapCoordinator.wasPaired,
                                                                   starting: !settings.handBackToWhoop),
                                 batteryPercent: strapInfo?.batteryPercent, charging: charging,
                                 offWristSince: offWristSince, offWristMayBeStale: wrist.mayBeStale,
                                 wearLocation: wearLocation,
                                 lastRecordAt: lastRecord, batteryEstimate: batteryEstimate,
                                 notConnectedReason: StrapCoordinator.notConnectedReason(strapLinkState,
                                                                                         handedBack: settings.handBackToWhoop))
        var shown = status
        if StrapDeviceChoice.stored == .whoop4 { shown = services.whoop4.strapStatus(lastRecordAt: lastRecord) }   // 0.6.0.11
        await services.live.set(ContextLive(strap: shown, history: StrapCoordinator.history(strapLinkState),
                                            sync: syncStatus, settings: settings, ledger: ledger, sessions: sessions,
                                            systemIsDark: systemIsDark, alerts: currentAlerts))
    }

    /// Strap battery: percent + estimated time left from the stored battery history (MGContext BatteryEstimator; Mo
    /// 2026-10-11). Read again every 5 min, or when the percent or the charging state changes.
    private func updateBatteryEstimate() async {
        guard !isSample else {
            batteryEstimate = nil
            return
        }
        let now = clock.now
        let featuresOn = featuresOnNow()
        await recordFeatures(featuresOn, at: now)
        let key = "\(strapInfo?.batteryPercent ?? -1)|\(charging.map { $0 ? "charging" : "not" } ?? "?")"
            + "|" + featuresOn.map(\.rawValue).sorted().joined(separator: ",")
        if let at = batteryEstimateAt, now.timeIntervalSince(at) < 300, batteryEstimateFor == key { return }
        batteryEstimateAt = now
        batteryEstimateFor = key
        let t = Int64(now.timeIntervalSince1970)
        guard let readings = try? await services.store.batteryReadings(
            from: t - Int64(BatteryEstimator.lookbackHours * 3600), to: t + 60) else { return }
        let learned = BatteryRateLearner.learn(readings: readings, spans: featureLog.spans, now: now, prior: batteryLearned)
        var toSave: BatteryLearnedRates?
        if learned.features != batteryLearned?.features || learned.basePercentPerHour != batteryLearned?.basePercentPerHour {
            toSave = learned
        }
        batteryLearned = learned
        batteryEstimate = BatteryEstimator.estimate(readings, now: now, chargingNow: charging, calendar: calendar,
                                                   featureLog: featureLog.spans, learned: learned)
        if let toSave { try? await services.kv.save(toSave, key: Self.batteryLearnedKey) }
    }

    /// The strap features running right now, as the app last heard from the strap (not as the switches are set).
    private func featuresOnNow() -> Set<StrapFeature> {
        var on = Set<StrapFeature>()
        if rawOpticalStatus.on { on.insert(.rawOptical) }
        if rawMotionStatus.on { on.insert(.rawMotion) }
        if ecgStatus.phase == .running { on.insert(.ecg) }
        if StrapCoordinator.history(strapLinkState) != nil { on.insert(.offload) }
        return on
    }

    /// Updates the feature log; writes the kv document only when the set of features changed, or every 15 min (T140).
    private func recordFeatures(_ on: Set<StrapFeature>, at now: Date) async {
        let before = Set(featureLog.spans.filter { $0.to == nil }.map(\.feature))
        featureLog.update(on: on, at: now)
        featureLog.prune(keepingSince: now.addingTimeInterval(-BatteryEstimator.lookbackHours * 3600))
        // Also every 15 min while a feature stays on: a killed app's open span is closed at the saved `lastUpdate`.
        let stale = !on.isEmpty && featureLogSavedAt.map { now.timeIntervalSince($0) >= 900 } ?? true
        guard before != on || stale else { return }
        featureLogSavedAt = now
        try? await services.kv.save(featureLog, key: Self.featureLogKey)
    }

    private func startTickers() {
        tickers.append(Task { [weak self] in
            while !Task.isCancelled {
                let secs = Double(60 - Calendar.current.component(.second, from: Date()))
                try? await Task.sleep(for: .seconds(max(1, secs)))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        })
        tickers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // R-094: a beat already rebuilt Live within the last half second (liveBeatArrived): skip, no double work.
                let since = ProcessInfo.processInfo.systemUptime - self.liveRefreshedAt
                if self.liveOnScreen, since >= LivePace.minGap { self.refreshLive() }
            }
        })
        // R-094 stall watch: a 0.25 s tick that measures how late it wakes. Late by more than `LivePace.stall` = the main
        // thread was blocked (the "freezes then unfreezes"); one line a minute at most goes to the strap log with the
        // worst stall and the slowest Live / full rebuild, so the next run shows which part blocks. Nothing else changes.
        tickers.append(Task { [weak self] in
            var expected = ProcessInfo.processInfo.systemUptime + LivePace.watchTick
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LivePace.watchTick))
                guard let self, !Task.isCancelled else { return }
                let t = ProcessInfo.processInfo.systemUptime
                if self.appActive, self.liveOnScreen, let line = self.livePace.noteWake(lateBy: t - expected, at: t) {
                    self.services.strap.noteExternal(line)
                }
                expected = t + LivePace.watchTick
            }
        })
    }

    var liveOnScreen: Bool { tab == .live || cover != nil || sessions.workout != nil }

    private func scheduleNextChange(_ at: Date) {
        nextChangeTask?.cancel()
        let wait = at.timeIntervalSince(clock.now)
        guard wait > 0, wait < 6 * 3600 else { return }
        nextChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 0.5))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Stored state

    private func loadStored() async {
        let kv = services.kv
        // Each read on its own: one unreadable document must not stop the others (the salt above all).
        var unreadable: [String] = []
        do { settings = try await kv.load(AppSettings.self, key: AppSettingsStore.settingsKey) ?? AppSettings() } catch {
            unreadable.append("settings (\(error))")
            // Keep the unreadable bytes under a second key before defaults are saved over them (nothing is lost).
            if let raw = try? await services.store.value(forKey: AppSettingsStore.settingsKey) {
                try? await services.store.setValue(raw, forKey: AppSettingsStore.settingsKey + ".unreadable")
            }
        }
        // T9746: the preset lists get their seed once (only into an empty list); saved with the next settings save.
        // T9973: the seed is the user's own local file (LocalPresetLoader), none is written in source.
        settings.presetLists.seedIfNeeded(from: LocalPresetLoader.load())
        await applySkippedNotifications()      // T9841
        do { ledger = try await kv.load(PeekLedger.self, key: AppSettingsStore.ledgerKey) ?? PeekLedger() } catch {
            unreadable.append("questions (\(error))")
        }
        do { sessions = try await kv.load(LiveSessions.self, key: AppSettingsStore.sessionsKey) ?? LiveSessions() } catch {
            unreadable.append("running sessions (\(error))")
        }
        do {
            testRunLog = try await kv.load(TestRunLog.self, key: TestRunLog.storeKey) ?? TestRunLog()
            publishTestRuns()
        } catch {
            unreadable.append("test runs (\(error))")
            if let raw = try? await services.store.value(forKey: TestRunLog.storeKey) {
                try? await services.store.setValue(raw, forKey: TestRunLog.storeKey + ".unreadable")
            }
        }
        do { profile = try await services.store.profile() ?? Profile() } catch {
            unreadable.append("profile (\(error))")
        }
        do { pcProfile = try await services.store.pcProfile() } catch {
            unreadable.append("PC profile copy (\(error))")
        }
        do { installSalt = try await services.store.installSalt() } catch {
            unreadable.append("install salt — the strap can't start (\(error))")
        }
        do { flagSnapshot = try await services.store.latestFlagSnapshot() } catch {
            unreadable.append("strap settings snapshot (\(error))")
        }
        if !unreadable.isEmpty { showNotice("Couldn't read: " + unreadable.joined(separator: "; ")) }
        if let saved = try? await kv.load(FeatureLogRecorder.self, key: Self.featureLogKey) {
            featureLog = FeatureLogRecorder(restoring: saved)   // spans left open by a killed app end where last seen
        }
        if let saved = try? await kv.load(BatteryLearnedRates.self, key: Self.batteryLearnedKey) {
            batteryLearned = saved
        }
        rebuildLogCatalogue()
        if let w = sessions.workout { liveBuffer.startWorkout(at: w.start) }
        // The wear location as last recorded (ALG-007), for "same as before".
        if let wear = try? await services.store.events(from: clock.now.addingTimeInterval(-30 * 86400), to: clock.now,
                                                       types: [.wear]).last {
            wearLocation = wear.wearLocation
            if case .wear(let f) = wear.payload, f.state == .off { wrist = OffWristTracker(restoredOffSince: wear.at) }
        }
    }

    /// Saves settings, the question ledger and the running sessions (kv). Errors become the notice line.
    func saveState() async {
        let kv = services.kv
        do {
            try await kv.save(settings, key: AppSettingsStore.settingsKey)
            try await kv.save(ledger, key: AppSettingsStore.ledgerKey)
            try await kv.save(sessions, key: AppSettingsStore.sessionsKey)
        } catch {
            showNotice("Settings weren't saved: \(error)")
        }
        await pushLive()
    }

    // MARK: Intents queue (WP-24)

    /// Applies the widget / Shortcuts queue, then publishes the widget snapshot (WP-27 rule 2: after the drain).
    func drainIntents() async {
        if let drainer = services.intents {
            intentsDraining = true
            let report = await drainer.drain()
            intentsDraining = false
            if let problem = report.problem { showNotice(problem) }
        }
        widgetPublishWanted = false
        await publishWidgetSnapshot()
    }

    /// Shortcuts and widgets offer Mo's own drink presets (IntentsEvents.swift: the app writes the catalogue).
    func writeIntentsCatalogue() {
        guard let location = IntentsAppGroup.location() else { return }
        let catalogue = IntentsCatalogue(
            drinks: settings.effectiveDrinks.map { IntentsDrink(name: $0.name, caffeineMg: $0.caffeineMg) },
            medications: IntentsCatalogue.standard.medications)
        do { try catalogue.save(to: location.directory) } catch {
            services.strap.noteExternal("intent catalogue not written: \(error)")
        }
    }

    // MARK: Night sounds (WP-26)

    private func watchNightSounds() {
        let ns = services.nightSounds
        tickers.append(Task { [weak self] in
            for await status in await ns.statusUpdates() {
                guard let self else { return }
                await self.nightSoundsStatusChanged(status)
            }
        })
    }

    private func nightSoundsStatusChanged(_ status: NightSoundsStatus) async {
        switch status {
        case .needsForeground:
            let end = lastContext.map { ctx in
                ComputeWindow.nightEnd(anchors: ctx.anchors, latestWake: settings.latestWake, calendar: calendar)
            } ?? clock.now.addingTimeInterval(8 * 3600)
            await services.notifyCenter.nightSoundsNeedsForeground(windowEnd: end)
        case .listening:
            await services.notifyCenter.cancelNightSoundsPrompt()
        default:
            break
        }
        await refresh()
    }
}

/// Small helpers for windows the composition derives from the anchors.
enum ComputeWindow {
    /// When tonight ends: L for the coming morning, else B + 9 h.
    static func nightEnd(anchors: PhaseAnchors, latestWake: [Int: TimeOfDay], calendar: Calendar) -> Date {
        ContextMath.latestWakeInstant(latestWake, after: anchors.bedtime, calendar: calendar)
            ?? anchors.bedtime.addingTimeInterval(9 * 3600)
    }
}

extension AppModel {
    /// T10004: what the sync chip may say before the first status read: "not set up" only when no PC is paired; a paired
    /// phone starts as offline with no last-sync time, which the chip shows as "PC connecting…" while `settling`.
    nonisolated static func initialSyncStatus() -> SyncStatus {
        if let creds = try? KeychainCredentialStore().load() { return SyncStatus(state: .offline, pcName: creds.pcName) }
        return .notSetUp
    }
}

extension AppModel {
    /// T9999: "Last record" on the strap sheet was the last LIVE beat only, so it read "Nothing recorded yet" while a history
    /// download ran (and after every launch, until a beat arrived) although hours of records were being stored. It is now the
    /// newer of the last live beat and the newest stored heart-rate second.
    func lastRecordAt() async -> Date? {
        let now = clock.now
        let stored: Date?
        if let c = storedRecordCache, now.timeIntervalSince(c.readAt) < 20 {
            stored = c.at
        } else {
            let to = Int64(now.timeIntervalSince1970)
            let newest: Int64? = (try? await services.store.newestHRSecond(atOrBefore: to)) ?? nil
            stored = newest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            storedRecordCache = (stored, now)
        }
        return StrapStatus.newestRecord(live: liveBuffer.lastBeatAt, stored: stored)
    }
}
