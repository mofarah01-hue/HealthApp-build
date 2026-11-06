import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Strap & sync (UX-SPEC §14, prototype `strapSheet`). A sheet: strap rows · history download + last ack · strap write
// log (pushes inside the sheet) · strap settings (read-only snapshot) · R22 research stream (one write, confirm sheet) ·
// HR broadcast · PC Lab · Apple Health. Pure rendering of `StrapSyncState`; taps are `UIIntent`s.
// Owner: WP-13.
//
// Presenting: `.sheet { StrapSyncSheet(state:writeLog:send:close:) }`. `send(.pairPC)` is answered by the app
// presenting `PairingSheet`; `send(.openUnlock)` by the app calling `StrapLinking.prepareUnlock()` /
// `runUnlock(_:)`, which asks `UnlockConfirmPresenter` (see UnlockConfirmSheet.swift). The write log is data the
// app reads from the store (`StrapWriteEntry`), passed in so this view stays free of services.

private enum StrapSheetPage {
    case main
    case writeLog
    case settings
}

struct StrapSyncSheet: View {
    let state: StrapSyncState
    let writeLog: [StrapWriteEntry]
    let send: (UIIntent) -> Void
    let close: () -> Void
    /// r9v (T3): close the sheet, then send this intent once it has finished closing (a push sent while the sheet is
    /// still on its way out is dropped). nil = close and send at once (previews).
    let closeThen: ((UIIntent) -> Void)?
    /// WHOOP4-LINK (2026-11-05): the "Device" section (RootView passes `Whoop4DeviceSection`); nil = none (previews).
    let deviceSection: AnyView?

    @Environment(\.mgTheme) private var theme

    init(state: StrapSyncState, writeLog: [StrapWriteEntry] = [], send: @escaping (UIIntent) -> Void,
         close: @escaping () -> Void, closeThen: ((UIIntent) -> Void)? = nil, deviceSection: AnyView? = nil) {
        self.state = state
        self.writeLog = writeLog
        self.send = send
        self.close = close
        self.closeThen = closeThen
        self.deviceSection = deviceSection
    }

    var body: some View {
        ScrollView {
            StrapSyncContent(state: state, writeLog: writeLog, send: send, close: close, closeThen: closeThen,
                             deviceSection: deviceSection)
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.colors(for: theme).sheet.color.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
        .presentationBackground(Theme.colors(for: theme).sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }
}

/// The strap page's content (main, write log, strap settings list), shared by this sheet and the Device section of Settings (Nov 6 2026:
/// one settings page). `embedded` leaves out the sheet header and the PC Lab / Apple Health sections, which Settings has itself.
struct StrapSyncContent: View {
    let state: StrapSyncState
    let writeLog: [StrapWriteEntry]
    let send: (UIIntent) -> Void
    let close: () -> Void
    let closeThen: ((UIIntent) -> Void)?
    let deviceSection: AnyView?
    var embedded = false
    // Which page is showing. Navigation only; nothing expands from local state (BRIEF clarification).
    @State private var page: StrapSheetPage = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .main:
                StrapSyncMain(state: state, send: send, close: close, closeThen: closeThen, deviceSection: deviceSection,
                              openWriteLog: { page = .writeLog },
                              openSettings: { page = .settings }, embedded: embedded)
            case .writeLog:
                StrapWriteLogView(entries: writeLog, back: { page = .main })
            case .settings:
                StrapSettingsListView(line: state.settingsLine, rows: state.settingsRows, back: { page = .main })
            }
        }
    }
}

// MARK: - Main page

struct StrapSyncMain: View {
    let state: StrapSyncState
    let send: (UIIntent) -> Void
    let close: () -> Void
    let closeThen: ((UIIntent) -> Void)?
    let deviceSection: AnyView?
    let openWriteLog: () -> Void
    let openSettings: () -> Void
    /// Inside Settings: no sheet header, and no PC Lab / Apple Health (Settings has those).
    var embedded = false
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// r8h T1: the research switches sit behind one collapsed disclosure; local display state (nothing else needs it).
    @State private var researchOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded { header }
            if let deviceSection { deviceSection }   // WHOOP4-LINK: MG / none vs WHOOP 4.0, Pair WHOOP 4.0, status line
            inputDeviceSection        // 0.6.0.3 Ring live
            // What Mo checks daily comes first.
            strapSection
            streamsSection            // Nov 6 2026: the chosen device's streams, each its own switch, near the top
            historySection
            if !embedded {
                pcSection
                healthSection
            }
            hrReadSection             // 0.6.0.12: read the WHOOP 5.0's heart-rate broadcast
            autoRawSection            // r9q: the rest of the automatic raw settings (lengths, kinds, 50 Hz log)
            settingsSection
            researchDisclosure
            if researchOpen {
                // Rare research rows last; the rows only an MG has are not offered while the WHOOP 4.0 is chosen.
                if state.showsMGOnlyRows {
                    rawOpticalSection
                    ecgMotionSection
                    unlockSection
                    handBackSection
                }
            }
        }
    }

    /// One collapsed "Research" row: raw optical, ECG, motion, the R22 stream and hand-back.
    private var researchDisclosure: some View {
        Button {
            withAnimation(MGMotion.expand(reduceMotion: reduceMotion)) { researchOpen.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Research").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    Text("Raw optical, ECG, motion, the R22 stream, hand the strap back")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.mute.color)
                    .rotationEffect(.degrees(researchOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, MGSpace.section)
        .accessibilityElement(children: .combine)
        .accessibilityValue(researchOpen ? "open" : "closed")
        .accessibilityHint(researchOpen ? "Closes the research switches" : "Opens the research switches")
    }

    // MARK: streams (Nov 6 2026)

    /// "Streams, uses strap battery": raw optical (MG), raw motion, automatic bursts, during workouts, heart-rate broadcast.
    private var streamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Streams", note: "uses strap battery")
            MGCard {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.streamToggles) { LiveToggleRow(toggle: $0, send: send) }
                    if let line = state.streamMotionLine { autoRawLine(line) }
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Strap · PC Lab · Health")
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Spacer(minLength: 8)
                MGButton("Done", style: .ghost, action: close)
            }
            Text(state.deviceName == "MG" ? "Strap & sync" : "Strap & sync · \(state.deviceName)")
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text("The app finds your strap by what it is, not by its name.")
                .mgFont(.body)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: strap

    private var strapSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Strap")
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.strapRows.enumerated()), id: \.element.id) { index, row in
                        StrapValueRow(row: row) {
                            if row.id == "worn" { wearMenu }
                        }
                        if index < state.strapRows.count - 1 || !hasWornRow {
                            StrapRule()
                        }
                    }
                    if !hasWornRow {
                        HStack {
                            Text("Wear location").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            Spacer(minLength: 8)
                            wearMenu
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minHeight: 52)
                    }
                    if !state.changeWearLocation.enabled {
                        Text(state.changeWearLocation.disabledReason ?? "Changing the wear location is unavailable.")
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let connect = state.connect {
                        StrapActionButton(action: connect, style: .filled, send: send)
                            .padding(16)
                    }
                }
            }
        }
    }

    private var hasWornRow: Bool { state.strapRows.contains { $0.id == "worn" } }

    /// "Change" → the places the strap can be worn (contract `wearLocation`). Picking one sends
    /// `.changeWearLocation(place)`; the intent inside `changeWearLocation` is only a default.
    private var wearMenu: some View {
        Menu {
            ForEach(WearLocation.allCases, id: \.self) { place in
                Button(strapWearTitle(place)) { send(.changeWearLocation(place)) }
            }
        } label: {
            Text(state.changeWearLocation.title)
                .mgFont(.button)
                .foregroundStyle(colors.ink.color)
                .padding(.horizontal, 14)
                .frame(minHeight: MGSpace.tapTarget)
                .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .disabled(!state.changeWearLocation.enabled)
        .accessibilityLabel("Change where the strap is worn")
    }

    /// 0.6.0.3 Ring live: "Input device" picker (Auto / WHOOP strap / Ring), which one is active now, the ring's steps.
    @ViewBuilder private var inputDeviceSection: some View {
        if let section = state.inputDevice {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Input device", note: "what feeds the live heart rate")
                MGCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Input device").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            Spacer(minLength: 8)
                            Menu {
                                ForEach(section.options) { option in
                                    Button(option.title) { if let intent = option.intent { send(intent) } }
                                        .disabled(!option.enabled)
                                }
                            } label: {
                                Text(section.currentTitle)
                                    .mgFont(.button)
                                    .foregroundStyle(colors.ink.color)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: MGSpace.tapTarget)
                                    .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                                    .contentShape(Capsule())
                            }
                            .accessibilityLabel("Input device")
                        }
                        ForEach(Array(section.detailLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// T124: the raw optical "every X" schedule. Each row already bakes in the current workout / still-wrist
    /// settings (`StrapSyncPresenter.rawOpticalEveryOptions`), so picking one cannot disturb the other two.
    private var rawOpticalEveryMenu: some View {
        Menu {
            ForEach(state.rawOpticalEveryOptions) { option in
                Button(option.title) { if let intent = option.intent { send(intent) } }
            }
        } label: {
            Text(state.rawOpticalEveryLabel)
                .mgFont(.button)
                .foregroundStyle(colors.ink.color)
                .padding(.horizontal, 14)
                .frame(minHeight: MGSpace.tapTarget)
                .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .accessibilityLabel("Raw optical schedule")
    }

    // MARK: history + write log

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("History", note: "strap → phone")
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Download").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            Spacer(minLength: 8)
                            Text(state.historyLine)
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink2.color)
                                .multilineTextAlignment(.trailing)
                        }
                        if let fraction = progressFraction {
                            ProgressView(value: fraction)
                                .tint(colors.ink.color)
                                .accessibilityLabel("History download")
                                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                        }
                        if let ack = state.lastAckLine {
                            Text(ack).mgFont(.body).foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 52)
                    .accessibilityElement(children: .combine)

                    StrapRule()

                    Button(action: openWriteLog) {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Strap write log").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                                Text(writeLogSummary).mgFont(.detail).foregroundStyle(colors.ink2.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens every write sent to the strap")
                }
            }
        }
    }

    /// 0…1, or nil when no download is running (an unknown end shows no percentage, only the line).
    private var progressFraction: Double? {
        guard let p = state.historyProgress, p.isFinite else { return nil }
        return min(max(p, 0), 1)
    }

    /// The state's line ends in a chevron ("clock set ×1 today ›"); the row draws its own.
    private var writeLogSummary: String {
        state.writeLogLine.trimmingCharacters(in: CharacterSet(charactersIn: " ›"))
    }

    // MARK: strap settings (117/118/128 snapshot)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Strap settings", note: "read only")
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: openSettings) {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Feature flags").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                                Text(state.settingsLine).mgFont(.detail).foregroundStyle(colors.ink2.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.settingsRows.isEmpty)
                    .accessibilityHint("Opens every flag and value read from the strap")
                    StrapRule()
                    StrapActionButton(action: state.readSettings, style: .ghost, send: send)
                        .padding(16)
                }
            }
        }
    }

    // MARK: raw optical (108 live R20, off by default)

    /// Wave W12b (#103): "Hand the strap back to WHOOP" and what the last hand-back put back.
    @ViewBuilder private var handBackSection: some View {
        if let toggle = state.handBack {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Leave no trace", note: "puts the strap back as WHOOP had it")
                MGCard {
                    VStack(alignment: .leading, spacing: 8) {
                        LiveToggleRow(toggle: toggle, send: send)
                        ForEach(Array(state.handBackLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Wave W8 (2026-10-11): "ECG (MG)" and "Raw motion (100 Hz)", each off by default (CLAUDE.md rule 5).
    @ViewBuilder private var ecgMotionSection: some View {
        if let s = state.ecgMotion {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("ECG and raw motion", note: "research · off by default")   // T147 (wave W11 had "on by default")
                MGCard {
                    VStack(alignment: .leading, spacing: 8) {
                        LiveToggleRow(toggle: s.ecg, send: send)
                        Text(s.ecgLine)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        MGButton(s.wrist.title, style: .ghost) { if let i = s.wrist.intent { send(i) } }
                            .disabled(!s.wrist.enabled)
                        Text("ECG and motion values are raw sensor counts, not units. A motion figure in mg is shown "
                             + "only after a still wrist has been checked against 1 g.")
                            .mgFont(.body)
                            .foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var rawOpticalSection: some View {
        if state.rawOptical != nil {      // its switch is in Streams
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Raw optical", note: "research")
                MGCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if let line = state.rawOpticalLine {
                            Text(line)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Wave 4 (#65): nights only, in the background, around the strap's SpO₂ bursts.
                        if let nights = state.rawOpticalNights {
                            LiveToggleRow(toggle: nights, send: send)
                            ForEach(Array(state.rawOpticalNightLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .mgFont(.body)
                                    .foregroundStyle(colors.ink2.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let workout = state.rawOpticalWorkout {
                            LiveToggleRow(toggle: workout, send: send)
                        }
                        if !state.rawOpticalEveryOptions.isEmpty {
                            HStack {
                                Text("Every X in the background").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                                Spacer(minLength: 8)
                                rawOpticalEveryMenu
                            }
                        }
                        if let whenStill = state.rawOpticalWhenStill {
                            LiveToggleRow(toggle: whenStill, send: send)
                        }
                        Text("Values are raw sensor counts, not units. Which light each block is has not been "
                             + "confirmed on this firmware.")
                            .mgFont(.body)
                            .foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// r9q: raw streams that switch on by themselves for workouts, bursts at quiet moments, the 50 Hz log.
    @ViewBuilder private var autoRawSection: some View {
        if let auto = state.autoRaw {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Automatic raw", note: "workouts and quiet moments")
                MGCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(auto.workoutLines.enumerated()), id: \.offset) { _, line in autoRawLine(line) }
                        ForEach(auto.kindToggles) { LiveToggleRow(toggle: $0, send: send) }
                        HStack {
                            Text("Length of one burst").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            Spacer(minLength: 8)
                            Menu {
                                ForEach(auto.lengthOptions) { option in
                                    Button(option.title) { if let intent = option.intent { send(intent) } }
                                }
                            } label: {
                                Text(auto.lengthLabel)
                                    .mgFont(.button)
                                    .foregroundStyle(colors.ink.color)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: MGSpace.tapTarget)
                                    .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                                    .contentShape(Capsule())
                            }
                            .accessibilityLabel("Length of one raw burst")
                        }
                        ForEach(Array(auto.burstLines.enumerated()), id: \.offset) { _, line in autoRawLine(line) }
                        ForEach(Array(auto.fiftyHzLines.enumerated()), id: \.offset) { _, line in autoRawLine(line) }
                    }
                }
            }
        }
    }

    private func autoRawLine(_ text: String) -> some View {
        Text(text)
            .mgFont(.body)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: unlock

    private var unlockSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("R22 research stream", note: state.unlockStatus)
            MGCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Changes one strap setting so the strap saves its extra detailed records (R22). Every "
                         + "setting is read and saved first, you confirm the change before anything is sent, and "
                         + "Restore puts the old value back. Afterwards the next downloads are checked for these records.")
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let watch = state.r22WatchLine {
                        Text(watch)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StrapActionButton(action: state.unlock, style: .filled, send: send)
                    if let restore = state.restoreR22 {
                        StrapActionButton(action: restore, style: .ghost, send: send)
                    }
                }
            }
        }
    }

    // MARK: read the 5.0 broadcast (0.6.0.12)

    @ViewBuilder private var hrReadSection: some View {
        if let hr = state.hrRead {
            MGCard {
                VStack(alignment: .leading, spacing: 8) {
                    LiveToggleRow(toggle: hr.toggle, send: send)
                    ForEach(Array(hr.lines.enumerated()), id: \.offset) { _, line in autoRawLine(line) }
                    ForEach(hr.candidates) { StrapActionButton(action: $0, style: .ghost, send: send) }
                    if let rescan = hr.rescan { StrapActionButton(action: rescan, style: .ghost, send: send) }
                    if let forget = hr.forget { StrapActionButton(action: forget, style: .ghost, send: send) }
                }
            }
            .padding(.top, 16)
        }
    }

    // MARK: PC Lab

    private var pcSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("PC Lab")
            MGCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        LiveStatusDot(tone: pcTone)
                        Text(pcWord)
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("PC Lab: \(pcWord)")
                    Text(state.pcLine)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let waiting = state.unsyncedLine {
                        Text(waiting)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let cleanup = state.cleanupLine {
                        Text(cleanup)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StrapActionButton(action: state.pair, style: state.pcState == .online ? .ghost : .filled, send: send)
                    if let panel = state.syncPanel {
                        SyncPanelView(panel: panel, send: send)
                    }
                }
            }
        }
    }

    private var pcWord: String {
        switch state.pcState {
        case .notSetUp: return "Not set up"
        case .pairing: return "Pairing…"
        case .offline: return "Offline"
        case .online: return "Online"
        case .error: return "Error"
        }
    }

    private var pcTone: StatusTone {
        switch state.pcState {
        case .notSetUp: return .neutral
        case .pairing: return .warn
        case .offline: return .warn
        case .online: return .good
        case .error: return .bad
        }
    }

    // MARK: Apple Health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Apple Health", note: "read + labelled mirror")
            MGCard {
                VStack(alignment: .leading, spacing: 8) {
                    if state.healthLines.isEmpty {
                        Text("Nothing from Apple Health yet.")
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                    } else {
                        ForEach(Array(state.healthLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // A second way in (2026-10-11: Mo couldn't find Today › M › Settings › Apple Health).
                    MGButton("Apple Health & Shortcuts ›", style: .ghost) {
                        if let closeThen { closeThen(.appleHealth(.open)) } else {
                            close()
                            send(.appleHealth(.open))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// A label on the left and its value on the right; blank values show their reason (ValueView).
struct StrapValueRow<Trailing: View>: View {
    let row: LabeledValue
    let trailing: Trailing
    @Environment(\.mgColors) private var colors

    init(row: LabeledValue, @ViewBuilder trailing: () -> Trailing) {
        self.row = row
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                if let caption = row.caption {
                    Text(caption).mgFont(.body).foregroundStyle(colors.ink2.color)
                }
            }
            Spacer(minLength: 8)
            ValueView(row.value, size: .inline)
                .frame(maxWidth: 190, alignment: .trailing)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

struct StrapRule: View {
    @Environment(\.mgColors) private var colors

    var body: some View {
        Rectangle()
            .fill(colors.rule.color)
            .frame(height: 1)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

/// An `ActionState` as a button. When it cannot run it is dimmed AND its reason is printed under it.
struct StrapActionButton: View {
    let action: ActionState
    let style: MGButton.Style
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    private var runnable: Bool { action.enabled && action.intent != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MGButton(action.title, style: style) {
                if let intent = action.intent { send(intent) }
            }
            .disabled(!runnable)
            .opacity(runnable ? 1 : 0.5)
            if !runnable {
                Text(reason)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reason: String {
        if let r = action.disabledReason, !r.isEmpty { return r }
        return action.enabled ? "Nothing is wired to this yet." : "Unavailable (no reason given)."
    }
}

/// The strap settings page: one row per feature flag of the newest snapshot (key, value as read, or why none).
struct StrapSettingsListView: View {
    let line: String
    let rows: [StrapSettingRow]
    let back: () -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MGButton("‹ Strap & sync", style: .ghost, action: back)
                Spacer(minLength: 8)
            }
            Text("Strap settings")
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .mgFont(.body)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.key).mgFont(.receipt).foregroundStyle(colors.ink.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let note = row.note {
                                    Text(note).mgFont(.body).foregroundStyle(colors.ink2.color)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(row.value).mgFont(.receipt).foregroundStyle(colors.ink.color)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minHeight: 52)
                        .accessibilityElement(children: .combine)
                        if index < rows.count - 1 { StrapRule() }
                    }
                }
            }
            Text("Values are the strap's own text. Meanings are only known for a few keys (noop PROTOCOL_CONFIGURATION).")
                .mgFont(.body)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}

/// Plain names for the contract's wear locations (the Log tab's wear question may word them differently).
func strapWearTitle(_ place: WearLocation) -> String {
    switch place {
    case .leftWrist: return "Left wrist"
    case .rightWrist: return "Right wrist"
    case .leftBicep: return "Left bicep"
    case .rightBicep: return "Right bicep"
    case .bodyTorso: return "Torso"
    case .bodyWaist: return "Waist"
    case .unknown: return "Not sure"
    case .tailboneUnderwear: return "Tailbone, in underwear"
    case .other: return "Somewhere else"
    }
}

// MARK: - Sync panel (P9734, 2026-10-14)

/// The expandable sync panel under PC Lab: a red banner when the PC has not accepted an upload for hours, a one-line
/// headline, and (opened) the strap-to-phone and phone-to-PC rows with "Sync now" and "Reset". Reset clears the re-pair
/// latch and the retry ladder and tries once; it never deletes anything queued.
struct SyncPanelView: View {
    let panel: SyncPanelState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner = panel.banner {
                HStack(spacing: 8) {
                    LiveStatusDot(tone: .bad)
                    Text(banner)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    group("Strap → phone", panel.strapToPhone)
                    group("Phone → PC", panel.phoneToPC)
                    StrapActionButton(action: panel.syncNow, style: .filled, send: send)
                    StrapActionButton(action: panel.reset, style: .ghost, send: send)
                    Text("Reset clears the “pair again” stop and the retry timer, then tries once. Nothing waiting on the phone is deleted; it stays until the PC confirms it.")
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text("Sync details · \(panel.headline)")
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func group(_ title: String, _ rows: [SyncPanelRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink.color)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
