import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore

// Settings › Command test (T87, 2026-10-13; Mo: CLAUDE.md rule 5 removed, nothing blocks a command). The logic is
// MGContext `CommandTestSession`; this file hands it the strap write (StrapLink.sendTestCommand, WITH RESPONSE) and the
// phone store (MGStore `command_test`; a mark is also written to `raw_frame`, so it goes to the PC in the raw drops).

/// The page's model: AppModel+CommandTest fills it; UI/CommandTest/CommandTestView.swift observes `state`.
@MainActor
final class CommandTestModel: ObservableObject {
    @Published var state: CommandTestState = .empty
    var session: CommandTestSession?
    /// P9726: refreshes the Raw optical (PPG) section about once a second while the page is on screen.
    var liveTask: Task<Void, Never>?
    /// P9726 / T124: the motion-polling bursts (runs until "Settings switch" is chosen again or the app quits).
    var motionTask: Task<Void, Never>?
}

@MainActor
final class CommandTestStoreAdapter: CommandTestStoring {
    private let store: MGStore
    private let strapId: () -> String
    private let now: () -> Date

    init(store: MGStore, strapId: @escaping () -> String, now: @escaping () -> Date) {
        self.store = store
        self.strapId = strapId
        self.now = now
    }

    func append(number: Int, payloadHex: String, at: Date) async throws -> Int64 {
        try await store.logCommandTest(number: number, payloadHex: payloadHex, at: at)
    }

    func setMark(id: Int64, mark: CommandTestMark) async throws {
        try await store.markCommandTest(id: id, mark: mark.rawValue, strapId: strapId(), at: now())
    }

    func observe(id: Int64, line: String) async throws {
        try await store.observeCommandTest(id: id, line: line, strapId: strapId(), at: now())
    }

    func observations() async throws -> [CommandTestObservation] {
        try await store.commandTestObservations(limit: 50).map { CommandTestObservation(entryID: $0.id, line: $0.line) }
    }

    func entries() async throws -> [CommandTestEntry] {
        try await store.commandTests(limit: 50).map {
            CommandTestEntry(id: $0.id, number: $0.number, payloadHex: $0.payloadHex, sentAt: $0.sentAt,
                             mark: $0.mark.flatMap(CommandTestMark.init(rawValue:)))
        }
    }
}

extension StrapActionError: LocalizedError {
    var errorDescription: String? { text }
}

extension AppModel {
    func commandTestAction(_ action: CommandTestAction) async {
        let model = commandTest
        let session = model.session ?? makeCommandTestSession()
        model.session = session
        if action == .open, paths[tab]?.last != .commandTest { push(.commandTest) }
        if action == .open { startCommandTestLive() }
        await session.handle(action)
        model.state = session.state
    }

    /// P9726: the live R20 window and raw-motion state, handed to the page once a second while it is on screen.
    private func startCommandTestLive() {
        let model = commandTest
        guard model.liveTask == nil else { return }
        model.liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = model.session, self.paths[self.tab]?.last == .commandTest else { break }
                let o = self.rawOpticalStatus, m = self.rawMotionStatus
                session.updateLive(RawPPGLive(wanted: self.settings.rawOpticalOn, on: o.on, frames: o.frames,
                                              lastFrameAt: o.lastFrameAt, stoppedReason: o.stoppedReason, recent: o.recent,
                                              windowRecords: RawOpticalStatus.recentSeconds, motionOn: m.on,
                                              motionSeconds: m.seconds, keepRawOnStrap: self.settings.keepRawOnStrap))
                model.state = session.state
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            model.liveTask = nil
        }
    }

    /// T124 motion polling (P9726). Bursts / continuous drive the link's raw-motion stream directly and are NOT saved;
    /// "Settings switch" hands it back to the saved switch (`applyRawMotion`). Re-asserted every 15 s, so a reconnect
    /// (which re-applies the saved switch) is corrected within 15 s.
    private func setCommandTestMotionPolling(_ choice: MotionPolling) {
        let model = commandTest
        model.motionTask?.cancel()
        model.motionTask = nil
        guard choice != .followSettings, !isSample else { return applyRawMotion() }
        let start = clock.now
        model.motionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let burst = choice.streams(elapsed: self.clock.now.timeIntervalSince(start)) ?? false
                self.services.strap.setRawMotion(enabled: burst || self.settings.rawMotionOn, foreground: true)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func makeCommandTestSession() -> CommandTestSession {
        let clock = self.clock
        return CommandTestSession(
            commands: StrapCommandTable.all().map { CommandTestCommand(number: $0.number, name: $0.name) },
            calendar: calendar, now: { clock.now },
            store: CommandTestStoreAdapter(store: services.store, strapId: { [weak self] in self?.strapInfo?.strapId.raw ?? "phone" },
                                           now: { clock.now }),
            send: { [weak self] opcode, payload in
                guard let self else { return }
                if self.isSample { throw StrapActionError("sample data is on: nothing is sent") }
                // WHOOP4-LINK: with "WHOOP 4.0" selected the frame goes to the 4.0 (CRC8 framing, 61080002), never the 5/MG.
                if StrapDeviceChoice.stored == .whoop4 {
                    try await self.services.whoop4.sendTestCommand(opcode: opcode, payload: payload)
                    return
                }
                try await self.services.strap.sendTestCommand(opcode: opcode, payload: payload)
            },
            rawOptical: { [weak self] on in await self?.setRawOptical(on) },
            motion: { [weak self] choice in self?.setCommandTestMotionPolling(choice) },
            keepRaw: { [weak self] on in await self?.setKeepRawOnStrap(on) })
    }
}
