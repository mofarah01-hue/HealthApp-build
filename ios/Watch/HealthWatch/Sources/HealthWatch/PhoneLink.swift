import Foundation
import WatchConnectivity

/// Sends every outbox file to the iPhone with WCSession.transferFile (queued by the system, survives app exit).
/// A file moves to `sent/` only after the system reports the transfer finished without error; nothing is deleted
/// here (Mo clears `sent/` from the app). Apple: developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    @Published private(set) var state = "Not connected"
    @Published private(set) var pending = 0
    @Published private(set) var sent = 0
    @Published private(set) var lastError: String?

    private var queued = Set<String>()       // names handed to WCSession and not finished yet

    static var sentDir: URL {
        let u = MGWFile.outbox.deletingLastPathComponent().appendingPathComponent("sent")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func activate() {
        guard WCSession.isSupported() else { state = "WatchConnectivity not supported"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendOutbox() {
        let s = WCSession.default
        guard s.activationState == .activated else { state = "Not activated yet"; return }
        for t in s.outstandingFileTransfers { queued.insert(t.file.fileURL.lastPathComponent) }
        let files = (try? FileManager.default.contentsOfDirectory(at: MGWFile.outbox, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "mgw" && !queued.contains(url.lastPathComponent) {
            s.transferFile(url, metadata: ["mgw": 1, "name": url.lastPathComponent])
            queued.insert(url.lastPathComponent)
        }
        pending = queued.count
        sent = ((try? FileManager.default.contentsOfDirectory(atPath: Self.sentDir.path)) ?? []).count
    }

    private func finished(_ url: URL, error: Error?) {
        queued.remove(url.lastPathComponent)
        if let error {
            lastError = "\(url.lastPathComponent): \(error.localizedDescription)"   // stays in outbox, retried next send
        } else {
            let dest = Self.sentDir.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: url, to: dest)
            }
        }
        pending = queued.count
        sent = ((try? FileManager.default.contentsOfDirectory(atPath: Self.sentDir.path)) ?? []).count
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        let companion = session.isCompanionAppInstalled
        Task { @MainActor in
            self.state = error.map { "Error: \($0.localizedDescription)" }
                ?? "Active · iPhone app \(companion ? "installed" : "NOT seen")\(reachable ? " · reachable" : "")"
            self.sendOutbox()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        Task { @MainActor in self.finished(url, error: error) }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.activate() }
    }
}
