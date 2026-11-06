import Foundation

/// The phone store behind the page (MGStore `command_test`; the adapter lives in the app).
public protocol CommandTestStoring: AnyObject {
    func append(number: Int, payloadHex: String, at: Date) async throws -> Int64
    func setMark(id: Int64, mark: CommandTestMark) async throws
    /// Newest first.
    func entries() async throws -> [CommandTestEntry]
    /// P9726: an observation line saved with the send `id` (written as text the PC receives; the mark is left alone).
    func observe(id: Int64, line: String) async throws
    /// Newest first.
    func observations() async throws -> [CommandTestObservation]
}

public extension CommandTestStoring {
    func observe(id: Int64, line: String) async throws {
        throw CommandTestStoreUnsupported()
    }
    func observations() async throws -> [CommandTestObservation] { [] }
}

public struct CommandTestStoreUnsupported: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "this store cannot save observations" }
}

/// Settings › Command test (T87, 2026-10-13; Mo: CLAUDE.md rule 5 removed, nothing blocks a command). Pure logic: the
/// strap write (`send`, WITH RESPONSE in MGBLE) and the store are handed in.
@MainActor
public final class CommandTestSession {
    public private(set) var state: CommandTestState = .empty

    private let commands: [CommandTestCommand]
    private let calendar: Calendar
    private let now: () -> Date
    private let store: CommandTestStoring
    private let send: (UInt8, [UInt8]) async throws -> Void
    private let rawOptical: ((Bool) async -> Void)?
    private let motion: ((MotionPolling) async -> Void)?
    private let keepRaw: ((Bool) async -> Void)?
    /// What the switch was last set to from this page, until the next `updateLive` brings the saved value.
    private var keepRawPending: Bool?
    private var live: RawPPGLive?
    private var meter = PPGRateMeter()
    private var motionChoice: MotionPolling = .followSettings
    private var observations: [CommandTestObservation] = []
    private var payload = ""
    private var on: Int?
    private var log: [CommandTestEntry] = []
    private var notice: String?
    /// r8h C1: the command in flight (one at a time).
    private var sending: Int?

    public init(commands: [CommandTestCommand], calendar: Calendar, now: @escaping () -> Date, store: CommandTestStoring,
                send: @escaping (UInt8, [UInt8]) async throws -> Void,
                rawOptical: ((Bool) async -> Void)? = nil, motion: ((MotionPolling) async -> Void)? = nil,
                keepRaw: ((Bool) async -> Void)? = nil) {
        self.keepRaw = keepRaw
        self.commands = commands
        self.rawOptical = rawOptical
        self.motion = motion
        self.calendar = calendar
        self.now = now
        self.store = store
        self.send = send
        publish()
    }

    public func handle(_ action: CommandTestAction) async {
        switch action {
        case .open:
            await reload()
        case .setPayload(let text):
            payload = text
            notice = nil
            publish()
        case .toggle(let number, let isOn):
            if !isOn {
                if on == number { on = nil }
                publish()
                return
            }
            guard sending == nil else { return }       // r8h C1: one send at a time; the buttons are disabled meanwhile
            guard let bytes = Self.parseHex(payload), let opcode = UInt8(exactly: number) else {
                notice = "Nothing sent: the payload isn't whole bytes of hex."
                publish()
                return
            }
            sending = number
            publish()
            if await sendAndLog(number: number, opcode: opcode, bytes: bytes) { on = number }
            sending = nil
            await reload()
        case .mark(let id, let mark):
            do { try await store.setMark(id: id, mark: mark) } catch { notice = "The mark couldn't be saved: \(error)" }
            await reload()
        case .setRawOptical(let isOn):
            guard let rawOptical else {
                notice = "Raw optical can't be switched from here."
                return publish()
            }
            await rawOptical(isOn)
            meter.reset()
            notice = nil
            // Logged as the command the app's switch path sends (108 [01 01] / [01 00]); the time is the tap.
            if let n = number(named: RawPPGPresenter.streamName) {
                await logOnly(number: n, bytes: isOn ? RawPPGPresenter.onPayload : RawPPGPresenter.offPayload)
            }
            await reload()
        case .observe(let observation):
            guard let entry = log.first else {
                notice = "Nothing to save it with yet: send a command or turn raw optical on first."
                return publish()
            }
            do {
                try await store.observe(id: entry.id, line: observation.line)
                notice = nil
            } catch {
                notice = "The observation couldn't be saved: \(Self.words(error))"
            }
            await reload()
        case .setMotionPolling(let choice):
            motionChoice = choice
            await motion?(choice)
            publish()
        case .setKeepRawOnStrap(let isOn):
            guard let keepRaw else {
                notice = "This switch can't be changed from here."
                return publish()
            }
            await keepRaw(isOn)
            keepRawPending = isOn
            notice = nil
            publish()
        case .setNightBanking(let isOn):
            guard let n = number(named: RawPPGPresenter.bankingName), let opcode = UInt8(exactly: n) else {
                notice = "Nothing sent: \(RawPPGPresenter.bankingName) is not in the protocol table."
                return publish()
            }
            _ = await sendAndLog(number: n, opcode: opcode,
                                 bytes: isOn ? RawPPGPresenter.onPayload : RawPPGPresenter.offPayload)
            await reload()
        }
    }

    /// About once a second while the page is open: the live R20 window and the raw-motion state.
    public func updateLive(_ input: RawPPGLive) {
        live = input
        keepRawPending = nil
        if input.on, let at = input.lastFrameAt { meter.note(frames: input.frames, at: at) }
        if !input.wanted { meter.reset() }
        publish()
    }

    /// One frame through `send`; logged only when it went out. Returns whether it was sent.
    private func sendAndLog(number: Int, opcode: UInt8, bytes: [UInt8]) async -> Bool {
        let at = now()
        do {
            try await send(opcode, bytes)
        } catch {
            notice = "Not sent: \(Self.words(error))"
            return false
        }
        notice = nil
        await logOnly(number: number, bytes: bytes, at: at)
        return true
    }

    private func logOnly(number: Int, bytes: [UInt8], at: Date? = nil) async {
        do {
            _ = try await store.append(number: number, payloadHex: bytes.map { String(format: "%02x", $0) }.joined(),
                                       at: at ?? now())
        } catch {
            notice = "Sent, but the log couldn't be saved: \(error)"
        }
    }

    private func number(named name: String) -> Int? {
        commands.first { $0.name == name }?.number
    }

    private func reload() async {
        do { log = try await store.entries() } catch { notice = "The log couldn't be read: \(error)" }
        do { observations = try await store.observations() } catch { notice = "Observations couldn't be read: \(error)" }
        publish()
    }

    private func publish() {
        let problem = Self.parseHex(payload) == nil ? "Hex bytes only, like 01 01." : nil
        state = CommandTestPresenter.make(commands: commands, on: on, payload: payload, payloadProblem: problem, log: log,
                                          notice: notice, calendar: calendar)
        state.ppg = ppgState()
        state.sending = sending
    }

    private func ppgState() -> RawPPGState {
        var p = RawPPGState()
        p.rawOpticalWanted = live?.wanted ?? false
        p.status = RawPPGPresenter.status(live, now: now())
        if let live, live.wanted {
            p.strips = RawPPGPresenter.strips(blocks: live.recent, frames: live.frames, windowRecords: live.windowRecords,
                                              recordsPerSecond: meter.recordsPerSecond)
        }
        p.motion = motionChoice
        if let live {
            p.motionStatus = live.motionOn ? "Raw motion streaming: \(live.motionSeconds) s since it went on"
                                           : "Raw motion not streaming now"
        }
        p.keepRawOnStrap = keepRawPending ?? live?.keepRawOnStrap ?? false
        p.nightBanking = RawPPGPresenter.nightBankingOn(log: log, bankingNumber: number(named: RawPPGPresenter.bankingName))
        let texts = Dictionary(state.log.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        p.observations = observations.enumerated().map { i, o in
            .init(id: i, text: "\(texts[o.entryID] ?? "send \(o.entryID)"): \(o.line)")
        }
        return p
    }

    private static func words(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// "01 0a" / "010A" / "" -> bytes; nil when not whole bytes of hex.
    static func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.filter { !$0.isWhitespace }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            guard let b = UInt8(digits[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
