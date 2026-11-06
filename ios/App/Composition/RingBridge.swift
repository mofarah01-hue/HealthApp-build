import CoreBluetooth
import Foundation
import MGBLE
import MGDomain

// 0.6.0.2 "Ring bridge" (Mo, Oct 26 2026: "the health app on tailscale should be able to have you control it ... one single
// time"). A generic BLE pass-through for a SECOND device (the MoYoung "M09" smart ring, ring-re/ in the repo root), driven
// from the PC through the remote debug channel: `mglab debug send ble op=<op> ...`. The phone is on Mo's body, so the ring's
// weak radio is in range; the PC holds the protocol knowledge and the allowlist (ring-re/PHASE0-RESEARCH.md §4).
//
// Own CBCentralManager, separate from the strap's: it never touches the WHOOP link. Everything sent and received is kept in
// memory for `drain` AND appended to Documents/ring-bridge/raw-<day>.jsonl (archive everything the device sends).
//
// The phone refuses the never-send list itself (defence in depth; PHASE0-RESEARCH.md §2): writes go only to fdd2, as FDDA
// frames, and never reset 3/0, shutdown 3/1, restart 3/14, binding 3/22, groups 4/6/7, OTA 0xF0+, alarm writes 9/1 {00,01,02}.

@MainActor
final class RingBridge {
    static let shared = RingBridge()

    enum Reply { case ok(JSONValue), fail(String) }

    private var central: CBCentralManager?
    private let proxy = RingBridgeProxy()
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var discoveryDone = false
    private var seen: [UUID: JSONValue] = [:]
    private var matchFDD0 = false
    private var events: [JSONValue] = []
    private var lastRead: [String: Data] = [:]
    private var keepAlive: Task<Void, Never>?
    private var autoReconnect = false
    private var droppedEvents = 0
    private let maxEvents = 50_000

    // 0.6.0.3 "Ring live": app-driven mode (the Settings "Input device" choice is Auto or Ring).
    /// One LiveBeat per 2A37 notification and per valid 1/9 spot result. AppModel decides whether they are used.
    var onBeat: ((LiveBeat) -> Void)?
    /// Called when the link state changes (connected / disconnected / discovered), for the Settings line.
    var onStateChange: (() -> Void)?
    /// Asked by the spot loop: is a live heart rate wanted right now (Live on screen and the ring is the active input)?
    var liveWanted: () -> Bool = { false }
    /// 0.6.0.5 "Ring lab": called for every logged event (time, direction tx / rx / mark, short characteristic, bytes, note).
    var onEvent: ((Date, String, String, Data?, String?) -> Void)?
    /// Newest fdd1 steps notification: steps, distance in metres, and when it arrived. Not stored anywhere in this version.
    private(set) var lastSteps: (steps: Int, distanceM: Int, at: Date)?
    private var autoMode = false
    private var spotLoop: Task<Void, Never>?
    private var spotResults = 0
    private var lastWriteAt = Date.distantPast
    private static let lastRingKey = "ringBridge.lastPeripheral"

    private init() { proxy.owner = self }

    /// The ring is connected and its services are discovered.
    var isConnected: Bool { peripheral?.state == .connected && discoveryDone }
    var displayName: String? { peripheral?.name }

    // MARK: app-driven mode (0.6.0.3)

    /// Connect to the remembered ring (a pending connect with no timeout), or scan for an FDD0 advert if none is known.
    /// Keep-alive and auto-reconnect stay on. Safe to call again.
    func startAuto() {
        autoMode = true
        autoReconnect = true
        if central == nil { central = CBCentralManager(delegate: proxy, queue: nil) }
        beginAutoConnect()
        startSpotLoop()
    }

    func stopAuto() {
        guard autoMode else { return }
        autoMode = false
        autoReconnect = false
        spotLoop?.cancel(); spotLoop = nil
        keepAlive?.cancel(); keepAlive = nil
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        log("mark", "", nil, note: "auto mode stopped")
        onStateChange?()
    }

    private func beginAutoConnect() {
        guard autoMode, let central, central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        if let s = UserDefaults.standard.string(forKey: Self.lastRingKey), let uuid = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adopt(p)
            log("mark", "", nil, note: "auto: connecting to remembered ring \(uuid.uuidString)")
            central.connect(p, options: nil)               // no timeout: iOS connects when the ring advertises
        } else {
            matchFDD0 = true
            seen.removeAll()
            log("mark", "", nil, note: "auto: scanning for an FDD0 ring")
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = proxy
        chars.removeAll()
        discoveryDone = false
    }

    func handleState(_ state: CBManagerState) {
        if state == .poweredOn { beginAutoConnect() }
    }

    /// Back-to-back HR spot readings while Live is on screen and the ring is the active input: start, wait for the 1/9
    /// result or 25 s, stop, wait 3 s, repeat. The ring streams 2A37 about once a second while a spot runs.
    private func startSpotLoop() {
        guard spotLoop == nil else { return }
        spotLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.autoMode, self.isConnected, self.liveWanted() else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let before = self.spotResults
                await self.sendFrame("fdda1007010901", note: "HR spot start")
                var waited = 0
                while waited < 25, !Task.isCancelled, self.spotResults == before, self.autoMode, self.isConnected,
                      self.liveWanted() {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                if self.isConnected { await self.sendFrame("fdda1007010900", note: "HR spot stop") }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// One allowlisted frame to fdd2, at least 1 s after the previous write. Returns why it was not sent, or nil when it was
    /// written (Ring lab shows the reason; the spot loop ignores it).
    @discardableResult
    func sendFrame(_ hex: String, note: String) async -> String? {
        guard let data = Data(hexString: hex) else { return "not valid hex" }
        if let why = Self.refusal(char: "fdd2", frame: data) { return "refused: \(why)" }
        guard let ch = chars["fdd2"] else { return "no fdd2 characteristic (ring not connected)" }
        let gap = Date().timeIntervalSince(lastWriteAt)
        if gap < 1 { try? await Task.sleep(nanoseconds: UInt64((1 - gap) * 1_000_000_000)) }
        guard let p = peripheral, p.state == .connected else { return "ring not connected" }
        log("tx", "fdd2", data, note: note)
        lastWriteAt = Date()
        p.writeValue(data, for: ch, type: ch.properties.contains(.write) ? .withResponse : .withoutResponse)
        return nil
    }

    /// Ring lab: read the standard battery level (2A19); the value arrives as an rx event.
    func readBattery() async {
        guard let ch = chars["2a19"] else { return }
        _ = await readValue(ch)
    }

    /// Ring lab: a mark line in the archive (Mo's worked / nothing / odd verdict on a button).
    func labMark(_ note: String) { log("mark", "", nil, note: note) }

    /// Timer alert (0.6.0.5, off unless Mo switches it on): find-ring buzz 3 s, then LED effect 1 for 3 s. Vibration is
    /// unconfirmed on this ring (tested Oct 26 1:26 AM: nothing felt), so the LED part is the one that may show.
    func timerAlert() async {
        guard isConnected else { return }
        await sendFrame("fdda1007090201", note: "timer alert: find ring start")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await sendFrame("fdda1007090200", note: "timer alert: find ring stop")
        await sendFrame("fdda1008031f0001", note: "timer alert: LED effect 1")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await sendFrame("fdda1008031f0100", note: "timer alert: LED off")
    }

    // MARK: ring notifications -> beats and steps (pure parsers are static, for tests)

    /// 2A37: flags byte, then bpm as u8 (flags bit 0 clear) or u16 LE (bit 0 set). nil when out of 30...230 or too short.
    static func parseHeartRate(_ d: Data) -> Int? {
        let b = [UInt8](d)
        guard b.count >= 2 else { return nil }
        let bpm: Int
        if b[0] & 1 == 1 {
            guard b.count >= 3 else { return nil }
            bpm = Int(b[1]) | Int(b[2]) << 8
        } else {
            bpm = Int(b[1])
        }
        return (30...230).contains(bpm) ? bpm : nil
    }

    /// fdd3 `FD DA 10 len 01 09 <v>`: the spot result. nil = not a result frame (also the 00 / 01 start and stop
    /// acknowledgements); `.some(nil)` = a result with no usable reading (0xFF); `.some(bpm)` = a reading.
    static func parseSpotResult(_ d: Data) -> Int?? {
        let b = [UInt8](d)
        guard b.count >= 7, b[0] == 0xFD, b[1] == 0xDA, b[2] == 0x10, b[4] == 0x01, b[5] == 0x09,
              b[6] != 0x00, b[6] != 0x01 else { return nil }
        if (30...230).contains(Int(b[6])) { return .some(Int(b[6])) }
        return .some(nil)
    }

    /// fdd1: [steps u24 LE][distance m u24 LE][third u24 LE].
    static func parseSteps(_ d: Data) -> (steps: Int, distanceM: Int)? {
        let b = [UInt8](d)
        guard b.count >= 6 else { return nil }
        return (Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16, Int(b[3]) | Int(b[4]) << 8 | Int(b[5]) << 16)
    }

    private func ringNotified(key: String, value v: Data) {
        switch key {
        case "2a37":
            if let bpm = Self.parseHeartRate(v) { onBeat?(LiveBeat(at: Date(), bpm: Double(bpm), rrMs: [])) }
        case "fdd3":
            if let r = Self.parseSpotResult(v) {
                spotResults += 1
                if let bpm = r { onBeat?(LiveBeat(at: Date(), bpm: Double(bpm), rrMs: [])) }
            }
        case "fdd1":
            if let s = Self.parseSteps(v) { lastSteps = (s.steps, s.distanceM, Date()) }
        default: break
        }
    }

    // MARK: entry point (called by AppModel.runRemoteDebug)

    func run(_ args: [String: JSONValue]) async -> RingBridge.Reply {
        func s(_ k: String) -> String? { if case .string(let v)? = args[k] { return v }; if case .number(let d)? = args[k] { return String(Int(d)) }; return nil }
        func i(_ k: String) -> Int? { s(k).flatMap { Int($0) } }
        if central == nil {
            central = CBCentralManager(delegate: proxy, queue: nil)
        }
        for _ in 0..<50 where central?.state == .unknown || central?.state == .resetting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard central?.state == .poweredOn else { return .fail("bluetooth not on (state \(central?.state.rawValue ?? -1))") }
        switch s("op") ?? "state" {
        case "scan": return await scan(seconds: min(max(i("secs") ?? 10, 1), 60), onlyFDD0: s("filter") != "all")
        case "connect": return await connect(id: s("id"), secs: min(max(i("secs") ?? 60, 5), 100),
                                             keepAliveSeconds: i("keepalive") ?? 30, auto: s("auto") != "0")
        case "write": return await write(char: s("char") ?? "fdd2", hex: s("hex") ?? "")
        case "read": return await read(char: s("char") ?? "")
        case "drain": return .ok(drain(max: min(max(i("max") ?? 3000, 1), 20_000)))
        case "disconnect": return disconnect()
        case "state": return .ok(stateJSON())
        default: return .fail("op must be scan | connect | write | read | drain | disconnect | state")
        }
    }

    // MARK: ops

    private func scan(seconds: Int, onlyFDD0: Bool) async -> RingBridge.Reply {
        seen.removeAll()
        matchFDD0 = onlyFDD0
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        central?.stopScan()
        return .ok(.object(["devices": .array(Array(seen.values))]))
    }

    private func connect(id: String?, secs: Int, keepAliveSeconds: Int, auto: Bool) async -> RingBridge.Reply {
        if let p = peripheral, p.state == .connected, discoveryDone { return .ok(stateJSON()) }
        var target: CBPeripheral?
        if let id, let uuid = UUID(uuidString: id) {
            target = central?.retrievePeripherals(withIdentifiers: [uuid]).first
        }
        if target == nil {                                   // wait for a live FDD0 advert (the ring advertises in short windows)
            matchFDD0 = true
            seen.removeAll()
            central?.scanForPeripherals(withServices: nil, options: nil)
            for _ in 0..<(secs * 2) where target == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                target = firstFDD0
            }
            central?.stopScan()
        }
        guard let target else { return .fail("no FDD0 ring advertising within \(secs) s — wake it (5 s on the charger)") }
        peripheral = target
        target.delegate = proxy
        chars.removeAll()
        discoveryDone = false
        autoReconnect = auto
        log("mark", "", nil, note: "connecting \(target.identifier.uuidString)")
        central?.connect(target, options: nil)              // iOS connect requests do not time out: fine for advert windows
        for _ in 0..<(secs * 4) where !discoveryDone {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard discoveryDone else { return .fail("connected=\(target.state == .connected), discovery not finished in \(secs) s") }
        // Read everything readable except the OTA / restore paths; values land in `events` and in the answer.
        var reads: [String: JSONValue] = [:]
        for (key, ch) in chars where ch.properties.contains(.read) && !Self.noRead(key) {
            if let v = await readValue(ch) { reads[key] = .string(v.hexString) }
        }
        startKeepAlive(seconds: keepAliveSeconds)
        var o = stateJSON()
        if case .object(var d) = o { d["reads"] = .object(reads); o = .object(d) }
        return .ok(o)
    }

    private func write(char: String, hex: String) async -> RingBridge.Reply {
        let key = Self.short(char)
        guard let data = Data(hexString: hex) else { return .fail("hex is not valid hex") }
        if let refusal = Self.refusal(char: key, frame: data) { return .fail("refused: \(refusal)") }
        guard let p = peripheral, p.state == .connected, let ch = chars[key] else { return .fail("not connected or no \(key)") }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        log("tx", key, data, note: type == .withResponse ? "with response" : "without response")
        p.writeValue(data, for: ch, type: type)
        return .ok(.object(["sent": .string(data.hexString), "char": .string(key)]))
    }

    private func read(char: String) async -> RingBridge.Reply {
        let key = Self.short(char)
        if Self.noRead(key) { return .fail("refused: \(key) is an OTA/restore path") }
        guard let ch = chars[key] else { return .fail("no \(key)") }
        guard let v = await readValue(ch) else { return .fail("no value from \(key) within 5 s") }
        return .ok(.object(["char": .string(key), "hex": .string(v.hexString)]))
    }

    private func drain(max: Int) -> JSONValue {
        let n = min(max, events.count)
        let out = Array(events.prefix(n))
        events.removeFirst(n)
        var o = stateJSON()
        if case .object(var d) = o {
            d["events"] = .array(out)
            d["remaining"] = .number(Double(events.count))
            d["dropped_since_start"] = .number(Double(droppedEvents))
            o = .object(d)
        }
        return o
    }

    private func disconnect() -> RingBridge.Reply {
        autoReconnect = false
        keepAlive?.cancel(); keepAlive = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        log("mark", "", nil, note: "disconnect requested")
        return .ok(stateJSON())
    }

    // MARK: keep-alive: set-clock 1/1 every N s (the ring drops a silent central after ~22 s; ring-re/LOG.md)

    private func startKeepAlive(seconds: Int) {
        keepAlive?.cancel()
        guard seconds > 0 else { return }
        keepAlive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let p = self.peripheral, p.state == .connected, let ch = self.chars["fdd2"] {
                    let f = Self.setClockFrame(Date())
                    self.log("tx", "fdd2", f, note: "set-clock 1/1 keep-alive")
                    self.lastWriteAt = Date()
                    p.writeValue(f, for: ch, type: .withoutResponse)
                }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    /// [epoch u32 LE][tz=8]; the local wall clock re-read as GMT+8, as the vendor app does (PHASE0-RESEARCH.md §1).
    static func setClockFrame(_ now: Date) -> Data {
        let offset = TimeZone.current.secondsFromGMT(for: now)
        let epoch = UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970) + offset - 8 * 3600)
        var f = Data([0xFD, 0xDA, 0x10, 11, 0x01, 0x01])
        withUnsafeBytes(of: epoch.littleEndian) { f.append(contentsOf: $0) }
        f.append(8)
        return f
    }

    // MARK: guards

    static func short(_ uuid: String) -> String {
        let u = uuid.lowercased()
        if u.count == 36, u.hasSuffix("-0000-1000-8000-00805f9b34fb") { return String(u.dropFirst(4).prefix(4)) }
        return u
    }

    static func noRead(_ key: String) -> Bool { key == "fdd5" || key == "fdd6" || key.hasPrefix("a6ed") }

    /// Why a write is refused, or nil. Only fdd2, only well-formed FDDA frames, never the dangerous opcodes.
    static func refusal(char: String, frame d: Data) -> String? {
        guard char == "fdd2" else { return "writes go only to fdd2" }
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 0xFD, b[1] == 0xDA, b[2] == 0x10 else { return "not an FD DA 10 frame" }
        guard Int(b[3]) == b.count else { return "length byte \(b[3]) != frame size \(b.count)" }
        let cmd = b[4], sub = b[5]
        if cmd >= 0xF0 { return "OTA command 0x\(String(cmd, radix: 16))" }
        if [4, 6].contains(cmd) { return "group \(cmd) is OTA / factory test" }
        // Group 7 (Gomore sleep / training, Da Rings decompile d1/b.java): the reads are allowed; 7/3 sends a licence key,
        // 7/11 ends a sleep; anything else in group 7 is refused until it is identified.
        if cmd == 7, ![0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 255].contains(sub) { return "7/\(sub) is a Gomore write or unknown" }
        if cmd == 3, [0, 1, 14, 22].contains(sub) { return "3/\(sub) is reset/shutdown/restart/binding" }
        if cmd == 9, sub == 1, b.count >= 7, [0, 1, 2].contains(b[6]) { return "9/1 {\(b[6])} is an alarm set/delete" }
        // From the Da Rings 1.3.5 decompile (d1/b.java, Oct 26 2026): destructive commands outside groups 3/4/6/7.
        let p0: UInt8? = b.count >= 7 ? b[6] : nil
        if cmd == 1, sub == 20 { return "1/20 is removeBond" }
        if cmd == 1, sub == 40, p0 == 0xFF { return "1/40 FF is deleteUserId" }
        if cmd == 1, sub == 41, p0 == 0x02 || p0 == 0xFF { return "1/41 is clearDeviceData / deletePINCode" }
        if cmd == 5, [1, 3, 8, 12].contains(sub) { return "5/\(sub) writes device settings/info/SN or resets activation" }
        if cmd == 10, sub == 4 { return "10/4 deletes recordings" }
        return nil
    }

    // MARK: plumbing

    private var firstFDD0: CBPeripheral? { fdd0Peripherals.first }
    private var fdd0Peripherals: [CBPeripheral] = []

    private func readValue(_ ch: CBCharacteristic) async -> Data? {
        let key = Self.short(ch.uuid.uuidString)
        lastRead[key] = nil
        peripheral?.readValue(for: ch)
        for _ in 0..<50 {
            if let v = lastRead[key] { return v }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func stateJSON() -> JSONValue {
        var d: [String: JSONValue] = [:]
        d["peripheral"] = peripheral.map { .string($0.identifier.uuidString) } ?? .null
        d["name"] = peripheral?.name.map { .string($0) } ?? .null
        d["connected"] = .bool(peripheral?.state == .connected)
        d["discovery_done"] = .bool(discoveryDone)
        d["keepalive_on"] = .bool(keepAlive != nil)
        d["auto_reconnect"] = .bool(autoReconnect)
        d["buffered_events"] = .number(Double(events.count))
        var cs: [String: JSONValue] = [:]
        for (k, ch) in chars { cs[k] = .string(Self.props(ch.properties)) }
        d["chars"] = .object(cs)
        return .object(d)
    }

    private static func props(_ p: CBCharacteristicProperties) -> String {
        var a: [String] = []
        if p.contains(.read) { a.append("read") }
        if p.contains(.write) { a.append("write") }
        if p.contains(.writeWithoutResponse) { a.append("write-without-response") }
        if p.contains(.notify) { a.append("notify") }
        if p.contains(.indicate) { a.append("indicate") }
        return a.joined(separator: ",")
    }

    private func log(_ dir: String, _ char: String, _ data: Data?, note: String? = nil) {
        var d: [String: JSONValue] = [:]
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d["ts"] = .string(f.string(from: Date()))
        d["dir"] = .string(dir)
        d["char"] = .string(char)
        d["hex"] = .string(data?.hexString ?? "")
        if let note { d["note"] = .string(note) }
        let e = JSONValue.object(d)
        onEvent?(Date(), dir, char, data, note)
        events.append(e)
        if events.count > maxEvents { events.removeFirst(); droppedEvents += 1 }
        RingBridgeFile.append(e)
    }

    // MARK: delegate callbacks (main queue)

    func handleDiscover(_ p: CBPeripheral, serviceData: [String: Data], services: [String], advName: String?,
                        manufacturer: Data?, rssi: Int) {
        var sd: [String: JSONValue] = [:]
        for (k, v) in serviceData { sd[Self.short(k)] = .string(v.hexString) }
        let isRing = sd.keys.contains("fdd0") || sd.keys.contains("fdda")
        if isRing, !fdd0Peripherals.contains(where: { $0.identifier == p.identifier }) { fdd0Peripherals.insert(p, at: 0) }
        if autoMode, isRing, peripheral == nil {
            central?.stopScan()
            adopt(p)
            log("mark", "", nil, note: "auto: found ring \(p.identifier.uuidString), connecting")
            central?.connect(p, options: nil)
        }
        if matchFDD0 && !isRing { return }
        var o: [String: JSONValue] = [:]
        o["id"] = .string(p.identifier.uuidString)
        o["name"] = (p.name ?? advName).map { .string($0) } ?? .null
        o["rssi"] = .number(Double(rssi))
        o["service_data"] = .object(sd)
        o["services"] = .array(services.map { .string(Self.short($0)) })
        o["manufacturer"] = manufacturer.map { .string($0.hexString) } ?? .null
        seen[p.identifier] = .object(o)
    }

    func handleConnect(_ p: CBPeripheral) {
        log("mark", "", nil, note: "connected")
        p.discoverServices(nil)
    }

    func handleDisconnect(_ p: CBPeripheral, error: Error?) {
        log("mark", "", nil, note: "DISCONNECTED" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        discoveryDone = false
        onStateChange?()
        if autoReconnect, p.identifier == peripheral?.identifier {
            log("mark", "", nil, note: "auto-reconnect pending")
            central?.connect(p, options: nil)
        }
    }

    func handleFail(_ p: CBPeripheral, error: Error?) {
        log("mark", "", nil, note: "connect failed" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }

    func handleServices(_ p: CBPeripheral) {
        let services = p.services ?? []
        pendingServices = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
        if services.isEmpty { discoveryDone = true }
    }

    func handleCharacteristics(_ p: CBPeripheral, service: CBService) {
        for ch in service.characteristics ?? [] {
            let key = Self.short(ch.uuid.uuidString)
            chars[key] = ch
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
        }
        pendingServices -= 1
        if pendingServices <= 0 {
            discoveryDone = true
            log("mark", "", nil, note: "discovered \(chars.count) characteristics")
            if autoMode {
                UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastRingKey)
                if keepAlive == nil { startKeepAlive(seconds: 30) }
            }
            onStateChange?()
        }
    }

    func handleValue(_ ch: CBCharacteristic, error: Error?) {
        let key = Self.short(ch.uuid.uuidString)
        if let error { log("mark", key, nil, note: "value error: \(error.localizedDescription)"); return }
        let v = ch.value ?? Data()
        lastRead[key] = v
        log("rx", key, v)
        ringNotified(key: key, value: v)
    }

    func handleWrite(_ ch: CBCharacteristic, error: Error?) {
        if let error { log("mark", Self.short(ch.uuid.uuidString), nil, note: "write error: \(error.localizedDescription)") }
    }
}

private final class RingBridgeProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: RingBridge?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        MainActor.assumeIsolated { owner?.handleState(s) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        var sd: [String: Data] = [:]
        for (k, v) in advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:] { sd[k.uuidString] = v }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        MainActor.assumeIsolated {
            owner?.handleDiscover(peripheral, serviceData: sd, services: services, advName: name, manufacturer: mfr, rssi: rssi)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { owner?.handleConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.handleFail(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.handleDisconnect(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { owner?.handleServices(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { owner?.handleCharacteristics(peripheral, service: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { owner?.handleValue(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { owner?.handleWrite(characteristic, error: error) }
    }
}

/// Append-only archive: Documents/ring-bridge/raw-YYYY-MM-DD.jsonl, one event per line.
private enum RingBridgeFile {
    static func append(_ e: JSONValue) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let line = try? JSONEncoder().encode(e) else { return }
        let dir = docs.appendingPathComponent("ring-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let url = dir.appendingPathComponent("raw-\(day).jsonl")
        var data = line
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let s = hexString.replacingOccurrences(of: " ", with: "").lowercased()
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
