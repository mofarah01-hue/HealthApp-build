import Combine
import Foundation
import MGContext

// 0.6.0.5 "Ring lab" (Mo, Oct 26 2026 ~1:25 AM): a Settings page to try the ring's features by hand and watch everything it
// sends. Every button sends ONE frame through RingBridge.sendFrame (its guard and its 1 s write spacing). This model keeps
// what the page shows: the last decoded reply per command, the live event list (newest 200), and the button log with Mo's
// worked / nothing / odd verdicts. Decoding is MGContext `RingFrames`. The log lives in memory; every send and every verdict
// is also a line in the RingBridge archive (Documents/ring-bridge), which the Command test store (strap numbers) cannot hold.

@MainActor
final class RingLabModel: ObservableObject {
    struct EventRow: Identifiable, Equatable {
        let id: Int
        let time: String
        let dir: String
        let char: String
        let hex: String
        let label: String?
    }

    struct LogRow: Identifiable, Equatable {
        let id: Int
        let time: String
        let title: String
        let frameHex: String
        let key: String?                 // "cmd sub" of the frame, to match the reply
        var reply: String?
        var mark: RingLabMark?
        var queuedAt: Date
        var sentAt: Date?
    }

    static let timerAlertKey = "ringLab.timerAlert"

    @Published var connected = false
    @Published var ringName: String?
    @Published var battery: String?
    @Published var firmware: String?
    @Published var steps: String?
    @Published var measureOn: [Int: Bool] = [:]
    @Published var results: [String: String] = [:]          // "cc ss" -> newest decoded reply
    @Published var autoN: [Int: Int] = [0x06: 0, 0x07: 0, 0x08: 0, 0x27: 0]
    @Published var temperatureAuto = false
    @Published var vibrationLevel = 0
    @Published var buzzType = 0
    @Published var gesturesOn = false
    @Published var gestureCount = 0
    @Published var ledOn = false
    @Published var ledEffect = 0
    @Published var timerAlert = UserDefaults.standard.bool(forKey: RingLabModel.timerAlertKey)
    @Published var notice: String?
    @Published var events: [EventRow] = []
    @Published var log: [LogRow] = []

    private var nextEvent = 0
    private var nextLog = 0
    private var chain: Task<Void, Never>?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm:ss a"
        return f
    }()

    /// Reads the live connection (name, steps) from RingBridge.
    func refreshConnection() {
        let ring = RingBridge.shared
        connected = ring.isConnected
        ringName = ring.displayName
        if let s = ring.lastSteps { steps = "\(s.steps) steps · \(s.distanceM) m · at \(clock.string(from: s.at))" }
    }

    /// One thing happened on the ring link (RingBridge.onEvent). Always on, so the list is already filled when the page opens.
    func ingest(at: Date, dir: String, char: String, data: Data?, note: String?) {
        let bytes = data.map { [UInt8]($0) } ?? []
        let label = dir == "rx" ? RingFrames.describe(char: char, bytes: bytes) : nil
        let text = dir == "mark" ? (note ?? "") : label ?? note
        nextEvent += 1
        events.insert(EventRow(id: nextEvent, time: clock.string(from: at), dir: dir, char: char,
                               hex: RingFrames.spaced(bytes), label: text), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        guard dir == "rx" else { return }
        switch char {
        case "2a19": battery = label
        case "fdd1": refreshConnection()
        case "fdd3":
            guard let key = RingFrames.commandKey(bytes), let label else { return }
            results[key] = label
            if key == "03 03" { firmware = label }
            if key == "03 17", gesturesOn { gestureCount += 1 }
            for i in log.indices where log[i].reply == nil && log[i].key == key
                && at.timeIntervalSince(log[i].sentAt ?? log[i].queuedAt) <= 3 {
                log[i].reply = label
            }
        default: break
        }
    }

    /// Queue one frame. They go out in order, one after another, each through RingBridge's guard and write spacing.
    func send(_ frame: [UInt8], title: String) {
        let previous = chain
        let hex = RingFrames.spaced(frame)
        nextLog += 1
        let id = nextLog
        log.insert(LogRow(id: id, time: clock.string(from: Date()), title: title, frameHex: hex,
                          key: RingFrames.commandKey(frame), reply: nil, mark: nil, queuedAt: Date(), sentAt: nil), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        chain = Task { @MainActor [weak self] in
            await previous?.value
            let why = await RingBridge.shared.sendFrame(RingFrames.hex(frame), note: "lab #\(id): \(title) \(hex)")
            guard let self else { return }
            if let i = self.log.firstIndex(where: { $0.id == id }) {
                if let why {
                    self.log[i].reply = "not sent: \(why)"
                    self.notice = why
                } else {
                    self.log[i].sentAt = Date()
                    self.notice = nil
                }
            }
        }
    }

    func setMark(_ id: Int, _ mark: RingLabMark) {
        guard let i = log.firstIndex(where: { $0.id == id }) else { return }
        log[i].mark = mark
        RingBridge.shared.labMark("lab #\(id) \(log[i].title) \(log[i].frameHex): \(mark.rawValue)")
    }

    func setTimerAlert(_ on: Bool) {
        timerAlert = on
        UserDefaults.standard.set(on, forKey: Self.timerAlertKey)
    }

    /// Read by TimersController when a timer ends.
    static var timerAlertOn: Bool { UserDefaults.standard.bool(forKey: timerAlertKey) }
}
