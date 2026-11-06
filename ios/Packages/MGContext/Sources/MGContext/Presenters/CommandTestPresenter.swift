import Foundation

/// One row of the protocol's CommandNumber table (whoop_protocol.json), as the app hands it in.
public struct CommandTestCommand: Equatable, Sendable {
    public var number: Int
    public var name: String

    public init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// One saved send (the phone store's `command_test` row).
public struct CommandTestEntry: Equatable, Sendable {
    public var id: Int64
    public var number: Int
    /// Lowercase hex, no spaces; "" = no payload.
    public var payloadHex: String
    public var sentAt: Date
    public var mark: CommandTestMark?

    public init(id: Int64, number: Int, payloadHex: String, sentAt: Date, mark: CommandTestMark?) {
        self.id = id
        self.number = number
        self.payloadHex = payloadHex
        self.sentAt = sentAt
        self.mark = mark
    }
}

public enum CommandTestPresenter {
    public static let disableLabel = "can disable the strap"

    /// Firmware, DFU, reboot, power cycle, ship mode, FORCE_TRIM (Mo, 2026-10-13); RESET_FUEL_GAUGE (99) added 2026-11-05
    /// with the WHOOP 4.0 link (D-WHOOP4-LINK-1: it is on the 4.0 inventory's red list). A label, never a gate.
    static func canDisableStrap(_ name: String) -> Bool {
        ["FIRMWARE", "DFU", "REBOOT", "POWER_CYCLE", "SHIP", "FORCE_TRIM", "FUEL_GAUGE"].contains { name.contains($0) }
    }

    /// "01 0A" from "010a".
    static func spaced(_ hex: String) -> String {
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            parts.append(String(hex[i..<j]).uppercased())
            i = j
        }
        return parts.joined(separator: " ")
    }

    public static func make(commands: [CommandTestCommand], on: Int?, payload: String, payloadProblem: String?,
                            log: [CommandTestEntry], notice: String?, calendar: Calendar) -> CommandTestState {
        let names = Dictionary(commands.map { ($0.number, $0.name) }, uniquingKeysWith: { a, _ in a })
        // r8h C1: the log is newest first, so the first entry per number is that command's last send.
        var newest: [Int: CommandTestEntry] = [:]
        for e in log where newest[e.number] == nil { newest[e.number] = e }
        return CommandTestState(
            commands: commands.map {
                .init(number: $0.number, name: $0.name, on: $0.number == on, canDisableStrap: canDisableStrap($0.name),
                      wasSent: newest[$0.number] != nil, lastMark: newest[$0.number]?.mark)
            },
            payload: payload, payloadProblem: payloadProblem,
            log: log.map { e in
                let shown = spaced(e.payloadHex)
                return .init(id: e.id,
                             text: "\(names[e.number] ?? "command") (\(e.number)) · payload \(shown.isEmpty ? "none" : shown)"
                                 + " · \(MGFormat.time(e.sentAt, calendar: calendar))",
                             mark: e.mark)
            },
            notice: notice)
    }
}
