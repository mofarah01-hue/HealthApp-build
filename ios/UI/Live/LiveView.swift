import SwiftUI
import MGContext
import MGDesign

// The Live tab (UX-SPEC §6). Pure rendering of `LiveState` (built by WP-23's presenter from the strap link);
// every tap is a `UIIntent` sent through `send`. Owner: WP-13.
//
// Scroll order (round 8, L13): SampleBanner (pinned, only in SAMPLE mode) · LiveHeader + stream chip · HRHero (HR, beat dot,
// RMSSD 5 min, autonomic load) · ActionGrid (Breathe, HRV check, ... right under the hero) · HR line (5 min, opens full from
// the store, #35) · "Waves" disclosure, collapsed (raw PPG with its cleaned line, 100 Hz motion, ECG; T146) · PulseWave (a
// real R26 wave only, or when the raw PPG row draws nothing) · Tachogram (R-R, 60 s, artefacts hollow) · StreamList ·
// BroadcastToggle · ResearchLinks.
// In Workout mode the hero / pulse wave / tachogram are replaced by `LiveWorkoutView`. With the strap off or not
// connected everything numeric is replaced by the reason (UX §13); actions stay and say why they are unavailable.
// Audit 7.3: the charts are Equatable wrappers over sub-states of `LiveState`, so a 1 Hz heart-rate change re-runs only the
// views whose own piece changed.
//
// The theme comes from the environment (RootView applies `.mgTheme`, WP-23); previews apply it themselves.

struct LiveView: View {
    let state: LiveState
    let send: (UIIntent) -> Void

    init(state: LiveState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                LiveHeader(state: state)
                    .padding(.top, MGSpace.m)
                    .padding(.bottom, MGSpace.l)

                mainBlock

                LiveActionGrid(actions: state.actions, send: send)       // L13: right after the heart-rate hero

                if state.workout == nil {
                    if state.blankReason == nil || !state.hrTrace.isEmpty {
                        LiveHRTraceBox(part: state.hrTracePart).equatable()
                    }
                }

                // One place for every case, so the picker choice and the open/closed state keep their identity (L11).
                LiveWavesSection(part: state.wavesPart, pulse: state.pulsePart, send: send).equatable()

                if state.workout == nil, state.blankReason == nil {
                    LivePulseBox(part: state.pulsePart).equatable()
                    LiveTachogramBox(part: state.tachogramPart).equatable()
                }

                streams

                broadcast

                // r9v (UI-SCRUB L14): the research links and the history test live in Settings › Decode lab now.
                LiveResearchMovedLink(send: send)

                // 0.6.0.12: only while the WHOOP 4.0 is the selected strap device.
                if let raw = state.whoop4RawLink {
                    LiveWhoop4RawLink(action: raw, send: send)
                }
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
        .onAppear { LiveFeedBridge.install() }
    }

    /// The hero block, or Workout mode, or the blank reason.
    @ViewBuilder private var mainBlock: some View {
        if let workout = state.workout {
            LiveWorkoutView(live: state, workout: workout, send: send)
        } else if let reason = state.blankReason {
            LiveBlankBlock(reason: reason, showOpenSettings: state.blankReasonNeedsSettings)
            // #35: connected and waiting for the first beat - the HR line (below) is already full from the store.
        } else {
            LiveHeartBlock(state: state)
        }
    }

    /// T148: master control and status lines share one card; per-stream switches remain in their wave rows.
    @ViewBuilder private var streams: some View {
        if !state.streamToggles.isEmpty || (state.blankReason == nil && !state.streams.isEmpty) {
            LiveStreamsCard(master: state.streamToggles.isEmpty ? nil : state.streamsMaster,
                            lines: state.blankReason == nil ? state.streams : [], send: send)
        }
    }

    private var broadcast: some View {
        MGCard {
            LiveToggleRow(toggle: state.broadcast, send: send, splitsStrapStatus: true)
        }
        .padding(.top, MGSpace.section)
    }
}

// MARK: - Equatable chart wrappers (audit 7.3)

/// The heart-rate line, re-run only when its own points, end or note change.
struct LiveHRTraceBox: View, Equatable {
    let part: LiveHRTraceSubState
    var body: some View { LiveHRTrace(points: part.points, end: part.end, note: part.note) }
}

/// The Pulse wave box: a real R26 wave, or the raw one only while the Raw PPG row draws nothing. Hidden otherwise (L1).
struct LivePulseBox: View, Equatable {
    let part: LivePulseSubState
    var body: some View {
        if !part.hidden {
            LivePulseWave(samples: part.samples, quality: part.quality, sample: part.sample,
                          blank: part.blank, pulseNote: part.note,
                          cleanSamples: part.cleanSamples, cleanChip: part.cleanChip, cleanNote: part.cleanNote)
        }
    }
}

/// The beat-to-beat chart.
struct LiveTachogramBox: View, Equatable {
    let part: LiveTachogramSubState
    var body: some View {
        LiveTachogram(points: part.points, median: part.median, end: part.end, note: part.note, liveBlank: part.blankReason)
    }
}
