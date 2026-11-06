import Foundation
import WhoopProtocol

/// A command that may be framed: sanctioned, policy-gated, or `test` (any number and payload, from the Command test page).
/// CHANGED 2026-10-13 (T87, Mo: CLAUDE.md rule 5 removed): nothing here refuses a command any more. Before, `.test` did not
/// exist, `ForbiddenOpcodes` threw `forbiddenOpcode` and a gated command threw `refusedByPolicy` unless its StrapPolicy
/// switch was on.
public enum StrapCommand: Equatable, Sendable {
    case sanctioned(SanctionedCommand)
    case gated(PolicyGatedCommand)
    case test(opcode: UInt8, payload: [UInt8])

    public var opcode: UInt8 {
        switch self {
        case .sanctioned(let c): return c.opcode
        case .gated(let c): return c.opcode
        case .test(let opcode, _): return opcode
        }
    }

    public var name: String {
        switch self {
        case .sanctioned(let c): return c.name
        case .gated(let c): return c.name
        case .test(let opcode, _): return "command \(opcode)"
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .sanctioned(let c): return c.payload
        case .gated(let c): return c.payload
        case .test(_, let payload): return payload
        }
    }
}

/// The ONLY place in the app that builds a strap command frame.
///
/// Frame layout (5/MG format 1, noop:docs/PROTOCOL_TRANSPORT.md): AA 01 len16 00 01 crc16 | 35 seq cmd payload
/// pad4 | crc32 — built by WhoopProtocol's `puffinCommandFrame` (golden-tested in the copied noop suite).
public struct CommandFramer: Sendable {
    public let policy: StrapPolicy

    public init(policy: StrapPolicy) {
        self.policy = policy
    }

    /// Frame `command` with sequence byte `seq`.
    public func frame(_ command: StrapCommand, seq: UInt8) throws -> [UInt8] {
        puffinCommandFrame(cmd: command.opcode, seq: seq, payload: command.payload)
    }
}

/// The 8-bit rolling request sequence (ARCHITECTURE §4.4.2: "Seq is an 8-bit rolling counter"). `next()`
/// increments then returns, as noop does (`seq = seq &+ 1`), so after `reset()` the first frame carries seq 1 —
/// which is what makes the CLIENT_HELLO byte-identical to the static Goose frame.
public struct SeqCounter: Sendable {
    public private(set) var last: UInt8

    public init(last: UInt8 = 0) {
        self.last = last
    }

    public mutating func next() -> UInt8 {
        last &+= 1
        return last
    }
}
