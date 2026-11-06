import Foundation
import MGContext

// Settings › Ring lab (0.6.0.5): turns each `RingLabAction` into one frame for RingLabModel.send (RingBridge's guard and
// write spacing apply). The page is pure rendering of RingLabModel.

extension AppModel {
    static let ringLabMeasureNames: [Int: String] = [0x09: "heart rate", 0x0A: "HRV", 0x0B: "SpO2", 0x0E: "stress",
                                                     0x20: "skin temperature", 0x19: "blood pressure"]
    static let ringLabAutoNames: [Int: String] = [0x06: "heart rate", 0x07: "HRV", 0x08: "SpO2", 0x27: "stress"]

    func ringLabAction(_ action: RingLabAction) async {
        let m = ringLab
        switch action {
        case .open:
            if paths[tab]?.last != .ringLab { push(.ringLab) }
            m.refreshConnection()
            await ringLabStatus()
        case .refreshStatus:
            m.refreshConnection()
            await ringLabStatus()
        case .measure(let sub, let on):
            m.measureOn[sub] = on
            m.send(RingFrames.measure(sub: UInt8(sub), on: on),
                   title: "measure \(Self.ringLabMeasureNames[sub] ?? String(sub)) \(on ? "on" : "off")")
        case .setAuto(let sub, let n):
            let v = min(max(n, 0), 12)
            m.autoN[sub] = v
            m.send(RingFrames.autoInterval(sub: UInt8(sub), n: v),
                   title: "automatic \(Self.ringLabAutoNames[sub] ?? String(sub)) \(v == 0 ? "off" : String(v))")
        case .setTemperatureAuto(let on):
            m.temperatureAuto = on
            m.send(RingFrames.temperatureAuto(on), title: "automatic temperature \(on ? "on" : "off")")
        case .readCurrent:
            for sub in RingFrames.readCurrentSubs { m.send(RingFrames.readSetting(sub: sub), title: "read setting \(String(format: "%02x", sub))") }
        case .setVibration(let level):
            m.vibrationLevel = min(max(level, 0), 3)
            m.send(RingFrames.vibrationLevel(m.vibrationLevel), title: "vibration level \(m.vibrationLevel)")
        case .readVibration:
            m.send(RingFrames.readVibration, title: "read vibration level")
        case .findRing(let on):
            m.send(RingFrames.findRing(on), title: "find ring \(on ? "start" : "stop")")
        case .notificationBuzz(let type):
            m.buzzType = min(max(type, 0), 15)
            m.send(RingFrames.notificationBuzz(type: m.buzzType), title: "notification buzz type \(m.buzzType)")
        case .setGestures(let on):
            m.gesturesOn = on
            if on { m.gestureCount = 0 }
            m.send(RingFrames.gestures(on), title: "gestures \(on ? "on" : "off")")
        case .readGestures:
            m.send(RingFrames.readGestures, title: "read gestures state")
        case .readLED:
            m.send(RingFrames.readLED, title: "read LED")
        case .setLED(let on):
            m.ledOn = on
            m.send(RingFrames.ledSwitch(on), title: "LED \(on ? "on" : "off")")
        case .setLEDEffect(let e):
            m.ledEffect = min(max(e, 0), 7)
            m.send(RingFrames.ledEffect(m.ledEffect), title: "LED effect \(m.ledEffect)")
        case .sendRaw(let text):
            guard let frame = RingFrames.fromTyped(text) else { m.notice = "That is not hex."; return }
            m.send(frame, title: "raw")
        case .mark(let id, let mark):
            m.setMark(id, mark)
        case .setTimerAlert(let on):
            m.setTimerAlert(on)
        }
    }

    /// Battery (2A19) and firmware (`03 03`).
    private func ringLabStatus() async {
        guard RingBridge.shared.isConnected else { return }
        ringLab.send(RingFrames.firmware, title: "read firmware")
        await RingBridge.shared.readBattery()
    }
}
