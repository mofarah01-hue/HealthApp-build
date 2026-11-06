import Foundation
import MGDomain

// T10012 (0.5.8.4 "Debug line"): the pure half of the remote debug channel. The PC queues a command (pclab/mglab/debug.py),
// the app long-polls GET /v1/debug/commands, runs each command ONE AT A TIME with a time limit, and posts the answer to
// POST /v1/debug/results. Nothing here touches the strap, the network or the database: the handler that does the work is
// handed in (App/Composition/AppModel+RemoteDebug.swift), so the queueing rules are tested on their own.
//
// Nothing in this build writes to the strap through this channel: the kinds below only read, or start a history download /
// a sync / the night chain that the app already runs by itself.

public enum RemoteDebug {
    /// Server cap on a long poll; the app asks for less so a lost connection is noticed soon.
    public static let pollWaitSeconds = 45

    public enum Kind: String, CaseIterable, Sendable {
        case logs
        case status
        case pullHistory = "pull_history"
        case syncNow = "sync_now"
        case runNight = "run_night"
        case readStrapSettings = "read_strap_settings"
        case ble                                         // 0.6.0.2 ring bridge: generic BLE pass-through to a second device

        /// How long the handler may take before the answer is "timed out" (the work is cancelled).
        public var timeLimit: TimeInterval {
            switch self {
            case .logs: return 60
            case .status: return 30
            case .pullHistory: return 30        // starts the download and answers; `status` shows how it goes
            case .syncNow: return 300
            case .runNight: return 900
            case .readStrapSettings: return 90
            case .ble: return 120
            }
        }
    }

    /// One command from the PC: `{id, kind, args}`. `kind` stays a string so a kind from a newer PC is answered with
    /// "unknown kind" instead of the whole poll failing to decode.
    public struct Command: Decodable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var args: [String: JSONValue]

        public init(id: String, kind: String, args: [String: JSONValue] = [:]) {
            self.id = id; self.kind = kind; self.args = args
        }

        enum CodingKeys: String, CodingKey { case id, kind, args }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            args = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .args)) ?? [:]
        }

        public var known: Kind? { Kind(rawValue: kind) }

        public func string(_ key: String) -> String? {
            switch args[key] {
            case .string(let s)?: return s
            case .number(let d)?: return d == d.rounded() ? String(Int(d)) : String(d)
            default: return nil
            }
        }

        public func int(_ key: String) -> Int? {
            switch args[key] {
            case .number(let d)?: return Int(exactly: d.rounded())
            case .string(let s)?: return Int(s)
            default: return nil
            }
        }
    }

    /// A text file that goes with an answer (stored by the PC next to the answer).
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    /// What a handler returns.
    public struct Outcome: Equatable, Sendable {
        public var ok: Bool
        public var result: JSONValue
        public var error: String?
        public var files: [File]

        public init(ok: Bool, result: JSONValue, error: String? = nil, files: [File] = []) {
            self.ok = ok; self.result = result; self.error = error; self.files = files
        }

        public static func success(_ result: JSONValue, files: [File] = []) -> Outcome {
            Outcome(ok: true, result: result, files: files)
        }

        public static func failure(_ why: String, result: JSONValue = .null) -> Outcome {
            Outcome(ok: false, result: result, error: why)
        }
    }

    /// The body of POST /v1/debug/results.
    public struct Answer: Encodable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var ok: Bool
        public var startedAt: Date
        public var finishedAt: Date
        public var result: JSONValue
        public var error: String?
        public var files: [File]

        public init(id: String, kind: String, ok: Bool, startedAt: Date, finishedAt: Date, result: JSONValue,
                    error: String?, files: [File]) {
            self.id = id; self.kind = kind; self.ok = ok; self.startedAt = startedAt; self.finishedAt = finishedAt
            self.result = result; self.error = error; self.files = files
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, ok, result, error, files
            case startedAt = "started_at"
            case finishedAt = "finished_at"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(ok, forKey: .ok)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(finishedAt, forKey: .finishedAt)
            try c.encode(result, forKey: .result)
            try c.encodeIfPresent(error, forKey: .error)
            if !files.isEmpty { try c.encode(files, forKey: .files) }
        }

        /// One line for the app's compute log: "debug: logs (cmd-1) ok in 1.2 s".
        public var logLine: String {
            let secs = String(format: "%.1f", max(0, finishedAt.timeIntervalSince(startedAt)))
            return "debug: \(kind) (\(id)) " + (ok ? "ok" : "FAILED: \(error ?? "no reason")") + " in \(secs) s"
        }
    }

    /// The commands of one poll answer. A malformed entry (no id) is dropped; the rest still run.
    public static func decodeCommands(_ body: Data) -> [Command] {
        struct Lossy: Decodable {
            var value: Command?
            init(from decoder: Decoder) throws { value = try? Command(from: decoder) }
        }
        struct Envelope: Decodable { var commands: [Lossy] }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: body) else { return [] }
        return e.commands.compactMap(\.value)
    }

    /// The `pending_commands` number of an app-status answer; 0 when absent (an older PC Lab).
    public static func pendingCommands(inStatusReply body: Data) -> Int {
        struct R: Decodable { var pendingCommands: Int?
            enum CodingKeys: String, CodingKey { case pendingCommands = "pending_commands" } }
        return max(0, (try? JSONDecoder().decode(R.self, from: body))?.pendingCommands ?? 0)
    }

    /// A text capped to its last `maxBytes` UTF-8 bytes, cut on a line start, with a first line saying what was cut.
    public static func tail(_ text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        var cut = bytes.count - maxBytes
        if let nl = bytes[cut...].firstIndex(of: 0x0A), nl + 1 < bytes.count {
            cut = nl + 1                                                  // start at a line
        } else {
            while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }   // never inside a character
        }
        return "[cut: older \(cut) of \(bytes.count) bytes left out]\n" + String(decoding: bytes[cut...], as: UTF8.self)
    }
}

// MARK: - Serial, time-limited execution

/// Runs commands one after another. A handler that runs past its limit is cancelled and answered "timed out" (the next
/// command does not wait for a handler that ignores cancellation). The answer to an id already run is returned again
/// without running it (the PC hands a command out again when it never got the answer).
///
/// One caller at a time: the poll loop. (An actor does not stop a second `run` interleaving at an `await`.)
public actor RemoteDebugDispatcher {
    public typealias Handler = @Sendable (RemoteDebug.Command) async -> RemoteDebug.Outcome

    private let handler: Handler
    private let now: @Sendable () -> Date
    private let limit: @Sendable (RemoteDebug.Kind) -> TimeInterval
    private let remember: Int
    private var answers: [String: RemoteDebug.Answer] = [:]
    private var order: [String] = []

    public init(handler: @escaping Handler,
                now: @escaping @Sendable () -> Date,
                limit: @escaping @Sendable (RemoteDebug.Kind) -> TimeInterval,
                remember: Int = 200) {
        self.handler = handler
        self.now = now
        self.limit = limit
        self.remember = remember
    }

    public func run(_ commands: [RemoteDebug.Command]) async -> [RemoteDebug.Answer] {
        var out: [RemoteDebug.Answer] = []
        for command in commands {
            if let again = answers[command.id] { out.append(again); continue }
            let started = now()
            let outcome: RemoteDebug.Outcome
            if let kind = command.known {
                let work = handler
                let seconds = limit(kind)
                let got = await Self.race(seconds: seconds) { await work(command) }
                outcome = got ?? .failure("timed out after \(Int(seconds)) s (the work was cancelled)")
            } else {
                outcome = .failure("unknown kind '\(command.kind)'; this build knows: "
                                   + RemoteDebug.Kind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let answer = RemoteDebug.Answer(id: command.id, kind: command.kind, ok: outcome.ok, startedAt: started,
                                            finishedAt: now(), result: outcome.result, error: outcome.error,
                                            files: outcome.files)
            answers[command.id] = answer
            order.append(command.id)
            if order.count > remember { answers[order.removeFirst()] = nil }
            out.append(answer)
        }
        return out
    }

    /// The work's outcome, or nil when `seconds` pass first (the work is then cancelled and not waited for).
    static func race(seconds: TimeInterval, work: @escaping @Sendable () async -> RemoteDebug.Outcome) async -> RemoteDebug.Outcome? {
        await withCheckedContinuation { (cont: CheckedContinuation<RemoteDebug.Outcome?, Never>) in
            let box = RaceBox(cont)
            box.setTimer(Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
                if box.finish(nil) { box.cancelJob() }
            })
            box.setJob(Task {
                let outcome = await work()
                if box.finish(outcome) { box.cancelTimer() }
            })
        }
    }
}

/// Resumes the continuation once, from whichever of the work and the timer gets there first.
private final class RaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteDebug.Outcome?, Never>?
    private var job: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(_ c: CheckedContinuation<RemoteDebug.Outcome?, Never>) { continuation = c }

    func finish(_ value: RemoteDebug.Outcome?) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(returning: value)
        return true
    }

    func setJob(_ t: Task<Void, Never>) { lock.lock(); job = t; lock.unlock() }
    func setTimer(_ t: Task<Void, Never>) { lock.lock(); timer = t; lock.unlock() }
    func cancelJob() { lock.lock(); let t = job; lock.unlock(); t?.cancel() }
    func cancelTimer() { lock.lock(); let t = timer; lock.unlock(); t?.cancel() }
}

// MARK: - The poll loop

/// How long to rest between polls.
public enum RemoteDebugBackoff {
    public enum Step: Equatable, Sendable {
        /// A poll ended with commands that were run.
        case ran
        /// A poll ended with nothing (the long poll timed out as it should).
        case idle
        case failed
        /// The PC cannot do this at all (an older PC Lab without the route, no PC paired): look again much later.
        case unavailable
    }

    /// `failures` = consecutive `.failed` / `.unavailable` steps including this one.
    public static func delay(after step: Step, failures: Int) -> TimeInterval {
        switch step {
        case .ran, .idle: return 0.5
        case .failed: return min(120, 5 * pow(2, Double(max(0, failures - 1))))      // 5, 10, 20, 40, 80, 120 s
        case .unavailable: return 600
        }
    }
}

public enum RemoteDebugPoll: Equatable, Sendable {
    case commands([RemoteDebug.Command])
    case empty
    case failed(String)
    case unavailable(String)
}

/// One loop for one phone: retry unsent answers, poll, run, post. The pieces that touch the network, the clock and the log
/// are handed in; `RemoteDebugLoopTests` drives it with fakes.
public actor RemoteDebugLoop {
    public struct Hooks: Sendable {
        /// Long poll for up to `wait` seconds.
        public var poll: @Sendable (_ wait: Int) async -> RemoteDebugPoll
        /// true = the PC has the answer (or will never take it: it no longer knows the command), so forget it.
        public var post: @Sendable (RemoteDebug.Answer) async -> Bool
        public var sleep: @Sendable (TimeInterval) async -> Void
        /// false = stop the loop (the on-phone off switch).
        public var shouldRun: @Sendable () -> Bool
        public var log: @Sendable (String) -> Void

        public init(poll: @escaping @Sendable (Int) async -> RemoteDebugPoll,
                    post: @escaping @Sendable (RemoteDebug.Answer) async -> Bool,
                    sleep: @escaping @Sendable (TimeInterval) async -> Void,
                    shouldRun: @escaping @Sendable () -> Bool,
                    log: @escaping @Sendable (String) -> Void) {
            self.poll = poll; self.post = post; self.sleep = sleep; self.shouldRun = shouldRun; self.log = log
        }
    }

    public static let maxUnsent = 50

    private let hooks: Hooks
    private let dispatcher: RemoteDebugDispatcher
    private var unsent: [RemoteDebug.Answer] = []
    private var failures = 0
    private var lastFailure: String?
    private var stepping = false

    public init(hooks: Hooks, dispatcher: RemoteDebugDispatcher) {
        self.hooks = hooks
        self.dispatcher = dispatcher
    }

    public var unsentCount: Int { unsent.count }

    /// One cycle. `wait` = 0 asks the PC for what is queued right now (the app-status `pending_commands` nudge).
    public func step(wait: Int) async -> RemoteDebugBackoff.Step {
        // Never two cycles at once (a restarted loop while the old one is finishing): the second one just rests.
        guard !stepping else { return .idle }
        stepping = true
        defer { stepping = false }
        await sendUnsent()
        let polled = await hooks.poll(wait)
        switch polled {
        case .unavailable(let why):
            failures += 1
            note(why)
            return .unavailable
        case .failed(let why):
            failures += 1
            note(why)
            return .failed
        case .empty:
            failures = 0; lastFailure = nil
            return .idle
        case .commands(let commands):
            failures = 0; lastFailure = nil
            if commands.isEmpty { return .idle }
            let answers = await dispatcher.run(commands)
            for a in answers {
                hooks.log(a.logLine)
                unsent.append(a)
            }
            if unsent.count > Self.maxUnsent { unsent.removeFirst(unsent.count - Self.maxUnsent) }
            await sendUnsent()
            return .ran
        }
    }

    /// Runs until cancelled or `shouldRun` says stop. Never throws.
    public func run() async {
        while !Task.isCancelled, hooks.shouldRun() {
            let s = await step(wait: RemoteDebug.pollWaitSeconds)
            await hooks.sleep(RemoteDebugBackoff.delay(after: s, failures: failures))
        }
    }

    private func sendUnsent() async {
        var left: [RemoteDebug.Answer] = []
        for a in unsent {
            if !left.isEmpty { left.append(a); continue }            // keep the order: one failure holds the rest back
            let accepted = await hooks.post(a)
            if !accepted { left.append(a) }
        }
        unsent = left
    }

    /// A failure is logged once per distinct reason, so a PC that is off all night does not fill the log.
    private func note(_ why: String) {
        guard why != lastFailure else { return }
        lastFailure = why
        hooks.log("debug channel: \(why)")
    }
}

// MARK: - Extra status-blob lines (T10010)

/// The three lines T10010 adds to the status blob the app posts every 5 minutes.
public struct StatusExtras: Equatable, Sendable {
    public var rawNight: String?
    public var launchTiming: String?
    public var batteryLearner: String?
    /// r9u: "apple health queue: 3 batches, 1.2 MB, 4500 samples; database maintenance: ..." (nil = not known yet).
    public var healthQueue: String?

    public init(rawNight: String? = nil, launchTiming: String? = nil, batteryLearner: String? = nil, healthQueue: String? = nil) {
        self.rawNight = rawNight; self.launchTiming = launchTiming; self.batteryLearner = batteryLearner
        self.healthQueue = healthQueue
    }
}

public enum BatteryLearnerSummary {
    /// "idle 1.2 %/h over 40.0 h · raw optical +0.8 %/h (measured, 12.0 h) · raw motion +0.5 %/h (guessed, 1.0 h) · fitted 2:10 AM".
    public static func line(_ learned: BatteryLearnedRates?, calendar: Calendar) -> String {
        guard let l = learned else { return "not fitted yet" }
        func f(_ d: Double) -> String { String(format: "%.1f", d) }
        var parts: [String] = []
        parts.append(l.basePercentPerHour.map { "idle \(f($0)) %/h over \(f(l.baseHours)) h" }
                     ?? "idle drain not known yet (\(f(l.baseHours)) h of usable discharge)")
        for r in l.features {
            parts.append("\(r.feature.rawValue) +\(f(r.percentPerHour)) %/h (\(r.measured ? "measured" : "guessed"), \(f(r.hours)) h)")
        }
        if let at = l.fittedAt { parts.append("fitted \(MGFormat.time(at, calendar: calendar))") }
        return parts.joined(separator: " · ")
    }
}
