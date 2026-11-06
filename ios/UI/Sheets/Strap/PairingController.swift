import Foundation
import MGSync

// PC Lab pairing, the logic half (ARCHITECTURE §5.2). The link is `mgapp://pair?v=1&base=<url-encoded base URL>&token=<token>&pc=<name>`,
// shown as a QR by `python -m mglab pair` (single use, valid 10 minutes). A scanned code, a pasted link and an
// `mgapp://` URL opened from outside all arrive here, are parsed with MGSync's `PairingPayload(url:)`, and are handed
// to the app's `pair` closure (WP-23: `SyncEngine.pair(_:deviceName:)`). Owner: WP-13.
//
// The token is a secret for 10 minutes: it is never shown, logged or echoed; an error message has it blanked out.

/// Why a typed or scanned string is not a pairing link, in words Mo can act on.
enum StrapPairingLinkError: Error, Equatable {
    case empty
    case notALink
    case notPairingLink
    case incomplete

    var message: String {
        switch self {
        case .empty:
            return "Paste the pairing link first."
        case .notALink:
            return "That isn't a readable link. It should look like mgapp://pair?v=1&base=…&token=…"
        case .notPairingLink:
            return "That isn't an MG pairing link. It must start with mgapp://pair."
        case .incomplete:
            return "The pairing link is incomplete: it needs v=1, a base address and a token. "
                + "Run python -m mglab pair again for a fresh one."
        }
    }
}

/// Parsing of a pairing link. Pure: `PairingPayload(url:)` does the real validation; this only tells the person
/// which part was wrong.
enum StrapPairingLink {
    static func parse(_ text: String) -> Result<PairingPayload, StrapPairingLinkError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed) else { return .failure(.notALink) }
        guard url.scheme?.lowercased() == "mgapp", url.host?.lowercased() == "pair" else {
            return .failure(.notPairingLink)
        }
        guard let payload = PairingPayload(url: url) else { return .failure(.incomplete) }
        return .success(payload)
    }
}

enum StrapPairingPhase: Equatable {
    /// Waiting for a code or a link.
    case ready
    case pairing(pcName: String)
    case paired(pcName: String)
    /// A sentence saying what went wrong.
    case failed(String)
}

@MainActor
final class PairingController: ObservableObject {
    @Published private(set) var phase: StrapPairingPhase = .ready

    private let pair: (PairingPayload) async throws -> Void
    private var lastRejected: (text: String, at: Date)?

    /// `pair` is WP-23's wiring to `SyncEngine.pair(_:deviceName:)`; it throws with a readable message on failure.
    init(pair: @escaping (PairingPayload) async throws -> Void) {
        self.pair = pair
    }

    /// A QR code was read. Ignored while a pairing runs or has finished; a code that was just rejected is not
    /// re-reported on every camera frame.
    func handleScanned(_ text: String) {
        guard isIdle else { return }
        if let last = lastRejected, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        start(text)
    }

    /// The pasted or typed link.
    func handleLink(_ text: String) {
        guard isIdle else { return }
        start(text)
    }

    /// An `mgapp://pair…` URL opened from outside the app (`.onOpenURL`).
    func handle(url: URL) {
        handleLink(url.absoluteString)
    }

    /// "Try again".
    func reset() {
        if case .pairing = phase { return }
        lastRejected = nil
        phase = .ready
    }

    private var isIdle: Bool {
        switch phase {
        case .ready, .failed: return true
        case .pairing, .paired: return false
        }
    }

    private func start(_ text: String) {
        switch StrapPairingLink.parse(text) {
        case .failure(let error):
            lastRejected = (text, Date())
            phase = .failed(error.message)
        case .success(let payload):
            run(payload)
        }
    }

    private func run(_ payload: PairingPayload) {
        phase = .pairing(pcName: payload.pcName)
        lastRejected = nil
        let pairClosure = pair
        Task { [weak self] in
            do {
                try await pairClosure(payload)
                self?.phase = .paired(pcName: payload.pcName)
            } catch {
                self?.phase = .failed(PairingController.describe(error, token: payload.token))
            }
        }
    }

    /// The error as a sentence, with the token blanked out if an error ever echoed it.
    static func describe(_ error: Error, token: String) -> String {
        var text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if !token.isEmpty { text = text.replacingOccurrences(of: token, with: "•••") }
        return text
    }
}
