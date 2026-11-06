import SwiftUI
import MGContext
import MGDesign

// Settings › Ring lab (0.6.0.5, Mo Oct 26 2026 ~1:25 AM). Try the ring's features by hand, see everything it sends, switch
// measurements on and off. Pure rendering of RingLabModel; the only output is `UIIntent.ringLab(_:)`. The hex under each
// control is the whole frame that goes out (FD DA 10 <length> <command> <sub> <payload>).

struct SettingsRingLabRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Ring lab", detail: "Try the ring's measurements, vibration, gestures and LED by hand and watch "
                        + "everything it sends.",
                        action: { send(.ringLab(.open)) }) { EmptyView() }
    }
}

struct RingLabScreen: View {
    @ObservedObject var model: RingLabModel
    let send: (UIIntent) -> Void

    init(model: RingLabModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        RingLabView(model: model, send: send)
    }
}

struct RingLabView: View {
    @ObservedObject var model: RingLabModel
    let send: (UIIntent) -> Void
    @State private var rawText = ""
    @State private var buzzType = 0
    @State private var ledEffect = 0
    @Environment(\.mgColors) private var colors

    private func hex(_ frame: [UInt8]) -> String { RingFrames.spaced(frame) }
    private func go(_ a: RingLabAction) { send(.ringLab(a)) }

    private static let measures: [(sub: Int, name: String, note: String?)] = [
        (0x09, "Heart rate", nil), (0x0A, "HRV", nil), (0x0B, "SpO2", "estimate"), (0x0E, "Stress", "estimate"),
        (0x20, "Skin temperature", "decoded, untested"), (0x19, "Blood pressure", "wellness estimate"),
    ]
    private static let autos: [(sub: Int, name: String)] = [(0x06, "Heart rate"), (0x07, "HRV"), (0x08, "SpO2"), (0x27, "Stress")]

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                    .padding(.top, 12)
                Text("Ring lab")
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .accessibilityAddTraits(.isHeader)
                if !model.connected {
                    SettingsSection("Status") { LogHint("No ring connected") }
                } else {
                    status
                    measure
                    automatic
                    vibration
                    gestures
                    led
                    raw
                    timerAlert
                }
                stream
                logSection
            }
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneBar()
    }

    // MARK: 1 Status

    private var status: some View {
        SettingsSection("Status") {
            SettingsRow("Connected", detail: model.ringName) { Text("yes") }
            SettingsRow("Battery", detail: model.battery ?? "not read yet") { EmptyView() }
            SettingsRow("Firmware", detail: model.results["03 03"] ?? "not read yet (03 03)") { EmptyView() }
            SettingsRow("Latest steps", detail: model.steps ?? "none received yet") { EmptyView() }
            SettingsRow("Read battery and firmware") {
                MGButton("Read", style: .ghost) { go(.refreshStatus) }
            }
        }
    }

    // MARK: 2 Measure now

    private var measure: some View {
        SettingsSection("Measure now", note: "on = 01 sub 01, off = 01 sub 00") {
            ForEach(Self.measures, id: \.sub) { m in
                let key = String(format: "01 %02x", m.sub)
                let last = model.results[key].map { "last: \($0)" } ?? "no result yet"
                SettingsRow(m.name + (m.note.map { " (\($0))" } ?? ""),
                            detail: "on \(hex(RingFrames.measure(sub: UInt8(m.sub), on: true)))\noff "
                                + "\(hex(RingFrames.measure(sub: UInt8(m.sub), on: false)))\n\(last)") {
                    Toggle(m.name, isOn: Binding(get: { model.measureOn[m.sub] ?? false },
                                                 set: { go(.measure(sub: m.sub, on: $0)) }))
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: 3 Automatic monitoring

    private var automatic: some View {
        SettingsSection("Automatic monitoring", note: "steps 0 to 12, 0 = off") {
            ForEach(Self.autos, id: \.sub) { a in
                let n = model.autoN[a.sub] ?? 0
                SettingsRow(a.name, detail: hex(RingFrames.autoInterval(sub: UInt8(a.sub), n: n))) {
                    Stepper(value: Binding(get: { model.autoN[a.sub] ?? 0 }, set: { go(.setAuto(sub: a.sub, n: $0)) }),
                            in: 0...12) { Text(n == 0 ? "off" : "\(n)").frame(maxWidth: .infinity, alignment: .trailing) }
                        .frame(maxWidth: 170)
                }
            }
            SettingsRow("Temperature",
                        detail: "on \(hex(RingFrames.temperatureAuto(true)))\noff \(hex(RingFrames.temperatureAuto(false)))") {
                Toggle("Temperature", isOn: Binding(get: { model.temperatureAuto },
                                                    set: { go(.setTemperatureAuto($0)) }))
                    .labelsHidden()
            }
            SettingsRow("Read current", detail: "sends 02 06, 02 07, 02 08, 02 2d, 02 15") {
                MGButton("Read current", style: .ghost) { go(.readCurrent) }
            }
            ForEach(RingFrames.readCurrentSubs, id: \.self) { sub in
                if let r = model.results[String(format: "02 %02x", sub)] { LogHint(r) }
            }
        }
    }

    // MARK: 4 Vibration

    private var vibration: some View {
        SettingsSection("Vibration") {
            SettingsRow("Level", detail: hex(RingFrames.vibrationLevel(model.vibrationLevel))) {
                Picker("Level", selection: Binding(get: { model.vibrationLevel }, set: { go(.setVibration(level: $0)) })) {
                    ForEach(0...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }
            SettingsRow("Read level", detail: hex(RingFrames.readVibration)) {
                MGButton("Read level", style: .ghost) { go(.readVibration) }
            }
            if let r = model.results["09 00"] { LogHint(r) }
            SettingsRow("Find ring", detail: "start \(hex(RingFrames.findRing(true)))\nstop \(hex(RingFrames.findRing(false)))") {
                HStack(spacing: MGSpace.s) {
                    MGButton("Start", style: .ghost) { go(.findRing(true)) }
                    MGButton("Stop", style: .ghost) { go(.findRing(false)) }
                }
            }
            SettingsRow("Notification buzz", detail: hex(RingFrames.notificationBuzz(type: buzzType))) {
                HStack(spacing: MGSpace.s) {
                    Stepper(value: $buzzType, in: 0...15) { Text("type \(buzzType)") }
                        .frame(maxWidth: 150)
                    MGButton("Buzz", style: .ghost) { go(.notificationBuzz(type: buzzType)) }
                }
            }
            LogHint("No reply yet = this ring may have no motor (tested Oct 26 1:26 AM: nothing felt)")
        }
    }

    // MARK: 5 Gestures

    private var gestures: some View {
        SettingsSection("Gestures") {
            SettingsRow("Gestures",
                        detail: "on \(hex(RingFrames.gestures(true)))\noff \(hex(RingFrames.gestures(false)))\n"
                            + "gestures seen since it went on: \(model.gestureCount)") {
                Toggle("Gestures", isOn: Binding(get: { model.gesturesOn }, set: { go(.setGestures($0)) }))
                    .labelsHidden()
            }
            SettingsRow("Read state", detail: hex(RingFrames.readGestures)) {
                MGButton("Read state", style: .ghost) { go(.readGestures) }
            }
            if let r = model.results["02 26"] { LogHint(r) }
        }
    }

    // MARK: 6 LED

    private var led: some View {
        SettingsSection("LED") {
            SettingsRow("Read", detail: hex(RingFrames.readLED)) {
                MGButton("Read", style: .ghost) { go(.readLED) }
            }
            if let r = model.results["03 1f"] { LogHint(r) }
            SettingsRow("Switch",
                        detail: "on \(hex(RingFrames.ledSwitch(true)))\noff \(hex(RingFrames.ledSwitch(false)))") {
                Toggle("LED", isOn: Binding(get: { model.ledOn }, set: { go(.setLED($0)) })).labelsHidden()
            }
            SettingsRow("Effect", detail: hex(RingFrames.ledEffect(ledEffect))) {
                HStack(spacing: MGSpace.s) {
                    Stepper(value: $ledEffect, in: 0...7) { Text("effect \(ledEffect)") }
                        .frame(maxWidth: 150)
                    MGButton("Send", style: .ghost) { go(.setLEDEffect(ledEffect)) }
                }
            }
        }
    }

    // MARK: 7 Raw command

    private var raw: some View {
        SettingsSection("Raw command", note: "command, sub, payload in hex, or a whole FD DA 10 frame") {
            LogTextField("01 09 01", text: $rawText)
                .padding(.vertical, 8)
            MGButton("Send", style: .ghost) { go(.sendRaw(rawText)) }
            if let n = model.notice { LogHint(n) }
        }
    }

    private var timerAlert: some View {
        SettingsSection("Timer") {
            SettingsRow("Ring alert when a timer ends",
                        detail: "find-ring buzz for 3 s, then LED effect 1 for 3 s. Vibration is unconfirmed on this ring.") {
                Toggle("Ring alert when a timer ends", isOn: Binding(get: { model.timerAlert },
                                                                     set: { go(.setTimerAlert($0)) }))
                    .labelsHidden()
            }
        }
    }

    // MARK: 8 Live stream, 9 Log

    private var stream: some View {
        SettingsSection("Live stream", note: "newest 200, tx = sent, rx = received") {
            if model.events.isEmpty { LogHint("Nothing yet.") }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.events) { e in
                    SettingsRow("\(e.time)  \(e.dir)  \(e.char)", detail: [e.hex, e.label].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: "\n")) { EmptyView() }
                }
            }
        }
    }

    private var logSection: some View {
        SettingsSection("Log", note: "newest first; mark what you saw") {
            if model.log.isEmpty { LogHint("Nothing sent yet.") }
            ForEach(model.log) { entry in
                SettingsRow("\(entry.time)  \(entry.title)",
                            detail: "\(entry.frameHex)\n" + (entry.reply.map { "reply: \($0)" } ?? "no reply seen")) {
                    Picker("Result", selection: Binding(
                        get: { entry.mark },
                        set: { if let m = $0 { go(.mark(entryID: entry.id, m)) } })) {
                        Text("result").tag(Optional<RingLabMark>.none)
                        ForEach(RingLabMark.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }
}
