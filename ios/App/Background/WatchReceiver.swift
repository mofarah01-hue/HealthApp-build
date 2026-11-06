// HealthApp (iPhone) side of the Watch link. Compiled into the app since 0.6.0.10 (wired in AppWiring; source and
// notes: watch/ios-integration, watch/INTEGRATION.md).
//
// Receives .mgw files the Watch sends with WCSession.transferFile, keeps them in Application Support/watch_inbox/
// (the system deletes its own copy when the delegate returns, so we copy first), and uploads each to PC Lab with
// PUT /v1/watch-files/<name>. A file moves to watch_inbox/uploaded/ only after the PC answers 200/201; nothing is deleted.
import Foundation
import CryptoKit
import WatchConnectivity

public final class WatchReceiver: NSObject, WCSessionDelegate {
    public static let shared = WatchReceiver()

    /// Set by the app at launch: uploads one file and returns true when the PC stored it.
    /// (name, bytes, sha256 hex) — wire to PCLabClient.putWatchFile (INTEGRATION.md).
    public var upload: ((String, Data, String) async throws -> Bool)?
    /// Optional log hook into the app's own logger.
    public var log: (String) -> Void = { print("[watch] \($0)") }

    private let queue = DispatchQueue(label: "watch.receiver")
    private var uploading = false

    public static var inbox: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch_inbox")
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("uploaded"), withIntermediateDirectories: true)
        return u
    }

    public func activate() {
        guard WCSession.isSupported() else { log("WatchConnectivity not supported"); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Counts for Settings / the debug channel.
    public func status() -> [String: Any] {
        let fm = FileManager.default
        let waiting = ((try? fm.contentsOfDirectory(atPath: Self.inbox.path)) ?? []).filter { $0.hasSuffix(".mgw") }.count
        let done = ((try? fm.contentsOfDirectory(atPath: Self.inbox.appendingPathComponent("uploaded").path)) ?? []).count
        let s = WCSession.isSupported() ? WCSession.default : nil
        return ["paired": s?.isPaired ?? false, "watch_app_installed": s?.isWatchAppInstalled ?? false,
                "inbox_waiting": waiting, "uploaded": done]
    }

    // MARK: WCSessionDelegate

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        guard name.hasSuffix(".mgw"), !name.contains("/") else { log("ignored file \(name)"); return }
        let dest = Self.inbox.appendingPathComponent(name)
        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: file.fileURL, to: dest)
            }
            log("received \(name)")
        } catch {
            log("could not keep \(name): \(error.localizedDescription)")
        }
        uploadInbox()
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        log("activated: \(activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)"
            + (error.map { " error=\($0.localizedDescription)" } ?? ""))
        uploadInbox()
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    // MARK: upload

    /// Uploads every waiting file, oldest name first. Call also after each sync and on app foreground.
    public func uploadInbox() {
        queue.async {
            guard !self.uploading, let upload = self.upload else { return }
            self.uploading = true
            Task {
                defer { self.queue.async { self.uploading = false } }
                let fm = FileManager.default
                let names = ((try? fm.contentsOfDirectory(atPath: Self.inbox.path)) ?? []).filter { $0.hasSuffix(".mgw") }.sorted()
                for name in names {
                    let url = Self.inbox.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    do {
                        if try await upload(name, data, sha) {
                            try? fm.moveItem(at: url, to: Self.inbox.appendingPathComponent("uploaded/\(name)"))
                        } else {
                            self.log("PC refused \(name)"); break
                        }
                    } catch {
                        self.log("upload \(name): \(error.localizedDescription)"); break   // retried next call
                    }
                }
            }
        }
    }
}
