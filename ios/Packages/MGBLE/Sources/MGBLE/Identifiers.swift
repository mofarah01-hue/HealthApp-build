import Foundation

/// GATT identifiers for the WHOOP 5/MG (ARCHITECTURE §4.4.1). Plain lowercase strings, not `CBUUID`, so the
/// link engine and its tests never touch CoreBluetooth; `CoreBluetoothTransport` converts.
///
/// Sources: noop:Strand/BLE/BLEManager.swift L531-559; noop:Packages/WhoopProtocol/Sources/WhoopProtocol/
/// DeviceFamily.swift L46-54 and L213-253 (the test `ScanFilterTests` pins these against WhoopProtocol's own
/// strings); Bluetooth SIG assigned numbers for 180D/2A37, 180F/2A19, 180A/2A24/2A26.
public enum StrapGATT {
    /// WHOOP 5.0 / MG service. The scan filter is this UUID and nothing else — never the advertised name, which
    /// is serial-style (letters and digits; example removed 2026-11-06 for the public build mirror) on real straps (project CLAUDE.md, finding L).
    public static let service = "fd4b0001-cce1-4033-93ce-002d5875f58a"
    /// Command characteristic. Every write to it is WITH RESPONSE (finding A: without-response writes are
    /// silently dropped by the 5/MG). `StrapTransport` has no without-response write at all.
    public static let write = "fd4b0002-cce1-4033-93ce-002d5875f58a"
    public static let notifyCommand = "fd4b0003-cce1-4033-93ce-002d5875f58a"
    public static let notifyEvents = "fd4b0004-cce1-4033-93ce-002d5875f58a"
    public static let notifyData = "fd4b0005-cce1-4033-93ce-002d5875f58a"
    public static let notifyLogs = "fd4b0007-cce1-4033-93ce-002d5875f58a"
    /// The four puffin notify characteristics, subscribed only AFTER the CLIENT_HELLO write is acknowledged
    /// (an unauthenticated subscribe wedges the bond: noop issue #17, BLEManager L6758-6770).
    public static let notify: [String] = [notifyCommand, notifyEvents, notifyData, notifyLogs]

    /// WHOOP 4.0 service: recognised (so a 4.0 is never mistaken for a 5/MG). This link (`StrapLink`) never connects to it; the
    /// 4.0 has its own path, `Whoop4Link` (`Whoop4GATT`, WHOOP4-LINK 2026-11-05, D-WHOOP4-LINK-1).
    public static let whoop4Service = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"

    /// Standard heart rate (works before the bond).
    public static let heartRateService = "180d"
    public static let heartRateMeasurement = "2a37"
    /// Standard battery. The 5/MG battery is read here, not by command 26 (noop BLEManager L7303-7309).
    public static let batteryService = "180f"
    public static let batteryLevel = "2a19"
    /// Device information (read-only identity strings).
    public static let deviceInfoService = "180a"
    public static let modelNumber = "2a24"
    public static let firmwareRevision = "2a26"

    /// CoreBluetooth state-restoration identifier (ARCHITECTURE §4.4.1).
    public static let restoreIdentifier = "mgapp.ble.central"

    /// Services → characteristics discovered on connect (ARCHITECTURE §4.4.2 step 2).
    public static let discoveryPlan: [String: [String]] = [
        service: [write] + notify,
        heartRateService: [heartRateMeasurement],
        batteryService: [batteryLevel],
        deviceInfoService: [modelNumber, firmwareRevision],
    ]

    public static var allKnownCharacteristics: Set<String> { Set(discoveryPlan.values.flatMap { $0 }) }

    /// Lowercased form used for every comparison (CoreBluetooth reports "180D", we store "180d").
    public static func normalize(_ uuid: String) -> String { uuid.lowercased() }
}
