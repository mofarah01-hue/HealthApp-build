// Ported from ryanbr/noop @ 2a1de76 (main, 2026-10-25): docs/PROTOCOL_WHOOP4.md "WHOOP 4 — service 61080001-…",
// Packages/WhoopProtocol DeviceFamily.swift (whoop4 UUIDs). PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import Foundation

/// GATT identifiers for the WHOOP 4.0 (WHOOP4-LINK, 2026-11-05; D-WHOOP4-LINK-1). Plain lowercase strings like `StrapGATT`.
/// A 4.0 has no `…0007` characteristic in noop's profile and no Device Information serial (the serial comes from
/// GET_HELLO_HARVARD), so neither is in the plan. Sources: noop docs/PROTOCOL_WHOOP4.md (UUID table); the test
/// `Whoop4LinkTests.testWhoop4IdentifiersMatchWhoopProtocol` pins these against WhoopProtocol's own strings.
public enum Whoop4GATT {
    /// The scan filter is this UUID and nothing else. The 5.0/MG service (`fd4b0001-…`) is a different UUID, so a
    /// service-filtered scan never sees a 5.0 (inventory §9).
    public static let service = StrapGATT.whoop4Service
    /// Command write. Every write is WITH RESPONSE; the first one is what bonds the strap ("just works", no iOS dialog).
    public static let write = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let notifyCommand = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let notifyEvents = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
    /// Large frames are split across ~244-byte notifications; the link reassembles them (WhoopProtocol `Reassembler`).
    public static let notifyData = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
    public static let notify: [String] = [notifyCommand, notifyEvents, notifyData]

    /// Services → characteristics discovered on connect (the standard heart-rate and battery services included).
    public static let discoveryPlan: [String: [String]] = [
        service: [write] + notify,
        StrapGATT.heartRateService: [StrapGATT.heartRateMeasurement],
        StrapGATT.batteryService: [StrapGATT.batteryLevel],
    ]

    public static var allKnownCharacteristics: Set<String> { Set(discoveryPlan.values.flatMap { $0 }) }
}

extension ScanFilter {
    /// The only filter the WHOOP 4.0 link uses: the 4.0 service UUID, never a name, never `fd4b0001`.
    public static let whoop4Strap = ScanFilter(serviceUUIDs: [Whoop4GATT.service])
}

/// Which strap Settings has selected (persisted; WHOOP4-LINK, D-WHOOP4-LINK-1). `mgOrNone` is what the app did before:
/// the 5/MG link when a strap was paired, nothing otherwise.
public enum StrapDeviceChoice: String, Codable, CaseIterable, Sendable {
    case mgOrNone = "mg_or_none"
    case whoop4 = "whoop4"

    public static let defaultsKey = "mg.device.choice"

    public var title: String {
        switch self {
        case .mgOrNone: return "MG / none"
        case .whoop4: return "WHOOP 4.0"
        }
    }

    /// The saved choice; `mgOrNone` until Settings changes it. Read synchronously at launch, before any link starts.
    public static var stored: StrapDeviceChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(StrapDeviceChoice.init(rawValue:)) ?? .mgOrNone
    }

    public static func store(_ choice: StrapDeviceChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: defaultsKey)
    }
}

/// The hard rule of D-WHOOP4-LINK-1 in one place: while "WHOOP 4.0" is the selected device, the app never scans for,
/// connects to, or restores a WHOOP 5.0/MG (`fd4b…`). Pure, so a test can pin it without a radio.
public enum StrapConnectPolicy {
    public enum Family: Equatable, Sendable { case mg, whoop4 }

    /// May the link of `family` scan or connect now? The 5/MG link also stays down while the strap is handed back to WHOOP
    /// (`StrapLink+HandBack.swift`); that switch is about the MG strap, so it does not stop a 4.0.
    public static func allows(_ family: Family, choice: StrapDeviceChoice, handedBack: Bool) -> Bool {
        switch family {
        case .mg: return choice == .mgOrNone && !handedBack
        case .whoop4: return choice == .whoop4
        }
    }

    /// What a scan may ask the radio for under `choice`; nil = no scan. For the 4.0 this is the 4.0 service only.
    public static func scanFilter(choice: StrapDeviceChoice, handedBack: Bool) -> ScanFilter? {
        switch choice {
        case .whoop4: return .whoop4Strap
        case .mgOrNone: return handedBack ? nil : .strap
        }
    }

    /// The family an advertisement belongs to, by its service UUIDs only (never the name). nil = neither. An
    /// advertisement that lists the 5/MG service is `.mg` even if it lists something else too.
    public static func family(advertised services: [String]) -> Family? {
        let s = Set(services.map(StrapGATT.normalize))
        if s.contains(StrapGATT.service) { return .mg }
        if s.contains(Whoop4GATT.service) { return .whoop4 }
        return nil
    }
}
