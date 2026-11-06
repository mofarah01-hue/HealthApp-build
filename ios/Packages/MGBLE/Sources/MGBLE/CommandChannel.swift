import Foundation
import WhoopProtocol

/// Frames, writes and correlates strap commands (ARCHITECTURE §4.4.2, last paragraph): every command is written
/// WITH RESPONSE and waits for its write-ack; when the caller asks, it then waits for the COMMAND_RESPONSE with
/// the same command and originating sequence (noop:docs/PROTOCOL_TRANSPORT.md "Responses and correlation"),
/// or `responseTimeout`. PENDING keeps the request open for the final answer.
@MainActor
final class CommandChannel {
    private struct Key: Hashable {
        let command: UInt8
        let origin: UInt8
    }

    private enum Slot {
        case expecting
        case arrived(CommandResponse)
        case waiting(CheckedContinuation<CommandResponse?, Never>, generation: UInt64)
    }

    private let transport: StrapTransport
    private let framer: CommandFramer
    private let responseTimeout: Double
    /// Where frames are written, and how a command becomes a frame. The defaults are the 5/MG's (`fd4b0002`, puffin
    /// framing); the WHOOP 4.0 link (`Whoop4Link`) passes its own `61080002` and CRC8 framing (WHOOP4-LINK, 2026-11-05).
    private let writeCharacteristic: String
    private let frameBuilder: ((StrapCommand, UInt8) -> [UInt8])?
    private var seq = SeqCounter()
    private var slots: [Key: Slot] = [:]
    private var generation: UInt64 = 0
    /// Requests that got a PENDING reply and no final one yet (for `send(pendingCounts:)`).
    private var pendingKeys: Set<Key> = []

    init(transport: StrapTransport, framer: CommandFramer, responseTimeout: Double,
         writeCharacteristic: String = StrapGATT.write, frameBuilder: ((StrapCommand, UInt8) -> [UInt8])? = nil) {
        self.transport = transport
        self.framer = framer
        self.responseTimeout = responseTimeout
        self.writeCharacteristic = writeCharacteristic
        self.frameBuilder = frameBuilder
    }

    /// Start a new connection's numbering: the next frame carries seq 1.
    func resetSequence() {
        seq = SeqCounter()
    }

    /// Test seam: make the next frame carry `last &+ 1` (lets a test reproduce noop's seq-0 ack golden).
    func presetSequence(last: UInt8) {
        seq = SeqCounter(last: last)
    }

    /// Frame, write with response, and
    /// optionally wait for the matching COMMAND_RESPONSE. Returns nil when not waiting or on timeout.
    /// `pendingCounts` (WHOOP 4.0, command 63): when the strap answered only PENDING and no final reply came before the timeout,
    /// return that PENDING as the answer (a synthetic response with an empty frame) instead of nil, so the caller can tell
    /// "accepted, answer not final" from "no answer at all".
    @discardableResult
    func send(_ command: StrapCommand, awaitResponse: Bool, pendingCounts: Bool = false) async throws -> CommandResponse? {
        let s = seq.next()
        let frame = try frameBuilder?(command, s) ?? framer.frame(command, seq: s)
        let key = Key(command: command.opcode, origin: s)
        if awaitResponse { slots[key] = .expecting }
        do {
            try await transport.writeWithResponse(Data(frame), to: writeCharacteristic)
        } catch {
            slots[key] = nil
            throw error
        }
        guard awaitResponse else { return nil }
        let answer = await waitForResponse(key)
        let sawPending = pendingKeys.remove(key) != nil
        if answer == nil, pendingCounts, sawPending {
            return CommandResponse(command: command.opcode, originSeq: s, result: .pending, body: [], frame: [])
        }
        return answer
    }

    /// Hand an inbound COMMAND_RESPONSE to whoever asked for it. Returns false when nobody did (unsolicited).
    @discardableResult
    func deliver(_ response: CommandResponse) -> Bool {
        let key = Key(command: response.command, origin: response.originSeq)
        guard let slot = slots[key] else { return false }
        if response.result == .pending {   // keep the request open for its final result
            pendingKeys.insert(key)
            return true
        }
        switch slot {
        case .expecting, .arrived:
            slots[key] = .arrived(response)
        case .waiting(let continuation, _):
            slots[key] = nil
            continuation.resume(returning: response)
        }
        return true
    }

    /// The link is gone: every waiter gets nil now.
    func failAll() {
        let pending = slots
        slots.removeAll()
        pendingKeys.removeAll()
        for (_, slot) in pending {
            if case .waiting(let continuation, _) = slot { continuation.resume(returning: nil) }
        }
    }

    private func waitForResponse(_ key: Key) async -> CommandResponse? {
        switch slots[key] {
        case .arrived(let response)?:
            slots[key] = nil
            return response
        case .expecting?:
            generation &+= 1
            let gen = generation
            let timeout = responseTimeout
            return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResponse?, Never>) in
                slots[key] = .waiting(continuation, generation: gen)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.expire(key, generation: gen)
                }
            }
        default:
            return nil
        }
    }

    private func expire(_ key: Key, generation gen: UInt64) {
        guard case .waiting(let continuation, let g)? = slots[key], g == gen else { return }
        slots[key] = nil
        continuation.resume(returning: nil)
    }
}

/// Ordered hand-off of offload frames to the history state machine, with an idle timeout
/// (noop BLEManager L2643-2660: 60 s without an offload frame ends the session).
@MainActor
final class FrameInbox {
    enum Next: Equatable {
        case frame([UInt8])
        case timeout
        case closed
    }

    private var buffer: [[UInt8]] = []
    private var head = 0
    private var waiter: CheckedContinuation<Next, Never>?
    private var timer: Task<Void, Never>?
    private(set) var isClosed = false

    func push(_ frame: [UInt8]) {
        guard !isClosed else { return }
        if let w = waiter {
            waiter = nil
            timer?.cancel()
            w.resume(returning: .frame(frame))
        } else {
            buffer.append(frame)
        }
    }

    func close() {
        isClosed = true
        buffer.removeAll()
        head = 0
        if let w = waiter {
            waiter = nil
            timer?.cancel()
            w.resume(returning: .closed)
        }
    }

    func next(timeout: Double) async -> Next {
        if head < buffer.count {
            let f = buffer[head]
            head += 1
            if head > 1024 { buffer.removeFirst(head); head = 0 }
            return .frame(f)
        }
        if isClosed { return .closed }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Next, Never>) in
            waiter = continuation
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, let w = self.waiter else { return }
                self.waiter = nil
                w.resume(returning: .timeout)
            }
        }
    }
}

/// Fan-out of a value stream to any number of `AsyncStream` consumers (Live tab, smart wake, intents).
@MainActor
final class Broadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func stream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func yield(_ value: Element) {
        for c in continuations.values { c.yield(value) }
    }
}
