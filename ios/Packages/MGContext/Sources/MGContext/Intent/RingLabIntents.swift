import Foundation

/// Settings › Ring lab (0.6.0.5). Sent as `UIIntent.ringLab(_:)`. Every case ends in one frame through RingBridge's guard.
public enum RingLabMark: String, CaseIterable, Equatable, Sendable {
    case worked, nothing, odd
}

public enum RingLabAction: Equatable, Sendable {
    /// Settings row: push the page and read the ring's battery and firmware.
    case open
    case refreshStatus
    /// Measure now: sub 0x09 HR, 0x0A HRV, 0x0B SpO2, 0x0E stress, 0x20 skin temperature, 0x19 blood pressure.
    case measure(sub: Int, on: Bool)
    /// Automatic monitoring: sub 0x06 HR, 0x07 HRV, 0x08 SpO2, 0x27 stress; n 0...12, 0 = off.
    case setAuto(sub: Int, n: Int)
    case setTemperatureAuto(Bool)
    case readCurrent
    case setVibration(level: Int)
    case readVibration
    case findRing(Bool)
    case notificationBuzz(type: Int)
    case setGestures(Bool)
    case readGestures
    case readLED
    case setLED(Bool)
    case setLEDEffect(Int)
    case sendRaw(String)
    case mark(entryID: Int, RingLabMark)
    /// "Ring alert when a timer ends" (off by default).
    case setTimerAlert(Bool)
}
