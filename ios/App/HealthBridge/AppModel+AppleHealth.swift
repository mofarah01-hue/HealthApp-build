import CryptoKit
import Foundation
import OSLog
import MGContext
import MGDomain
import MGHealth
import MGSync
import UIKit

// Settings › Apple Health — the Shortcuts bridge (Mo's decision 2026-10-11: URL schemes now, not App Intents).
//   IN : "Send today to Health" (or the automatic send after the morning compute) opens the Shortcut
//        "HealthApp → Health" with today's values as JSON (ShortcutHealthPayload: the Mirror's D12 rules); the
//        x-callback-url reply marks them as logged, or explains why not ("not found — build it (steps)").
//   OUT: the Shortcut "Health → HealthApp" POSTs to the PC Lab itself (the token comes from GET /v1/shortcut-token);
//        a `healthapp://import?data=…` link is the fallback: logged here and forwarded to POST /v1/health-samples.
// Every run is logged (what, when, result) in the `healthBridge.v1` document; SAMPLE mode sends nothing anywhere.

extension AppModel {
    private var bridge: HealthBridgeModel { healthBridge }
    static let healthSampleReason = "Sample data is on: nothing goes to Apple Health or the PC. Switch it off in Settings › Sample data."

    // MARK: Intents

    func appleHealth(_ action: AppleHealthAction) async {
        await bridgeLoad()
        switch action {
        case .open:
            showAppleHealthPage()
            if case .ready = bridge.token {} else { await fetchShortcutToken() }
        case .sendToday:
            await sendTodayToHealth(auto: false)
        case .setAutoSend(let on):
            if isSample, on {
                showNotice(Self.healthSampleReason)
            } else {
                bridge.doc.autoSend = on
                if !on { bridge.doc.autoWaiting = nil }
                await bridgeSave()
            }
        case .refreshToken:
            await fetchShortcutToken()
        case .copy(let what):
            copyForShortcut(what)
        case .toggleSteps(let id):
            if bridge.expanded.contains(id) { bridge.expanded.remove(id) } else { bridge.expanded.insert(id) }
        case .showSteps(let id):
            bridge.expanded.insert(id)
            showAppleHealthPage()
        case .runShortcut(let name):
            if isSample && name == ShortcutNames.healthOut {
                showNotice(Self.healthSampleReason)
            } else {
                closePendingRun()
                await runShortcut(name)
            }
        case .testInShortcut:
            // Nothing in the payload has a value the Shortcut logs, so this writes nothing to Health (also in SAMPLE).
            closePendingRun()
            await runShortcut(ShortcutNames.healthIn, text: ShortcutTestPayload.text,
                              what: "Test run of “\(ShortcutNames.healthIn)” (sends nothing)")
        case .forwardImports:
            await forwardImports()
        case .dismissBanner:
            bridge.banner = nil
        }
        await publishAppleHealth()
    }

    /// A new run replaces one still waiting for a reply (iOS 26.5+ often never replies): the old one is logged as
    /// "no reply" (Mo 2026-10-11: the run buttons must always be tappable).
    func closePendingRun() {
        guard let p = healthBridge.doc.pending else { return }
        finishShortcutRun(p, .noReply(shortcut: p.shortcut), result: nil, quiet: true)
    }

    /// The page, pushed once on the current tab's stack.
    func showAppleHealthPage() {
        if paths[tab]?.last != .appleHealth { push(.appleHealth) }
    }

    // MARK: IN — app → Apple Health

    func healthPayload(_ day: LocalDay) async -> ShortcutHealthPayload {
        let metrics = (try? await services.store.metrics(on: day)) ?? []
        return ShortcutHealthPayload.build(day: day, metrics: metrics, timeZone: calendar.timeZone,
                                           sentKeys: Set(bridge.doc.sentKeys.keys))
    }

    func sendTodayToHealth(auto: Bool) async {
        guard !isSample else { showNotice(Self.healthSampleReason); return }
        if let p = bridge.doc.pending {
            showNotice("Waiting for “\(p.shortcut)” to finish first.")
            return
        }
        let today = LocalDay(date: clock.now, calendar: calendar)
        let payload = await healthPayload(today)
        if auto {
            bridge.doc.lastAutoDay = today.iso
            bridge.doc.autoWaiting = nil
        }
        guard let text = payload.jsonText else {
            if !auto { showNotice(payload.skipped.first ?? "Nothing to send for today yet: last night's values come after the morning compute.") }
            await bridgeSave()
            return
        }
        await runShortcut(ShortcutNames.healthIn, text: text, keys: payload.items.map(\.key),
                          what: payload.items.map(\.summary).joined(separator: " · "), day: today.iso, auto: auto)
    }

    /// After a compute (AppModel.computeFinished): when the switch is on, today's night is final and something is new,
    /// send it — now if the app is in front, else at the next foreground (iOS opens another app only from the front).
    func appleHealthAfterCompute(_ report: ComputeReport) async {
        await bridgeLoad()
        let today = LocalDay(date: clock.now, calendar: calendar)
        guard bridge.doc.autoSend, !isSample, report.ran, !report.provisionalDays.contains(today),
              bridge.doc.lastAutoDay != today.iso else {
            await publishAppleHealth()
            return
        }
        let payload = await healthPayload(today)
        if payload.json != nil {
            if UIApplication.shared.applicationState == .active, bridge.doc.pending == nil {
                await sendTodayToHealth(auto: true)
            } else {
                bridge.doc.autoWaiting = today.iso
                await bridgeSave()
            }
        }
        await publishAppleHealth()
    }

    // MARK: Running a Shortcut (x-callback-url)

    /// Opens `shortcuts://x-callback-url/run-shortcut?name=…` and logs the run as pending until a callback (or no reply).
    /// Loads the log first: a save before the load would replace the stored log with this one run.
    func runShortcut(_ name: String, text: String? = nil, keys: [String] = [], what: String? = nil, day: String? = nil,
                     auto: Bool = false) async {
        await bridgeLoad()
        let rec = HealthSendRecord(id: UUID(), at: clock.now, shortcut: name, day: day, what: what ?? "Run “\(name)”",
                                   keys: keys, result: "pending", detail: nil, resultAt: nil, auto: auto)
        healthBridge.doc.sends.append(rec)
        healthBridge.doc.trim()
        let pending = HealthPendingRun(sendId: rec.id, shortcut: name, startedAt: rec.at, keys: keys)
        guard let url = ShortcutLink.run(name, text: text) else {
            finishShortcutRun(pending, .couldNotOpen(shortcut: name), result: nil)
            await bridgeSave()
            return
        }
        healthBridge.doc.pending = pending
        await bridgeSave()
        await publishAppleHealth()
        UIApplication.shared.open(url) { [weak self] ok in
            guard !ok else { return }
            Task { @MainActor in
                guard let self, let p = self.healthBridge.doc.pending, p.sendId == pending.sendId else { return }
                self.finishShortcutRun(p, .couldNotOpen(shortcut: name), result: nil)
                await self.bridgeSave()
                await self.publishAppleHealth()
            }
        }
    }

    /// `healthapp://…` (AppModel.handle(url:)).
    func handleHealthAppURL(_ url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bridgeLoad()
            if let cb = ShortcutLink.callback(url) {
                let raw = ShortcutLink.describe(url)
                Self.shortcutLog.notice("shortcut callback: \(raw ?? url.absoluteString, privacy: .public)")
                self.shortcutCallback(cb, raw: raw)
            } else if let link = ShortcutLink.importLink(url) {
                await self.importLinkArrived(link)
            } else {
                self.showNotice("HealthApp doesn't know the link healthapp://\(url.host ?? "").")
            }
            await self.bridgeSave()
            await self.publishAppleHealth()
        }
    }

    static let shortcutLog = Logger(subsystem: "mgapp", category: "shortcuts")

    func shortcutCallback(_ cb: ShortcutLink.Callback, raw: String? = nil) {
        if let p = bridge.doc.pending {
            var result: String?
            if case .ok(let r) = cb { result = r }
            finishShortcutRun(p, ShortcutOutcome.from(cb, shortcut: p.shortcut), result: result, raw: raw)
            return
        }
        // No run waiting: a late reply to a run already marked "no reply" (Mo came back before it finished), or the
        // Tailscale notification's own run. Update the late one; otherwise just say what happened.
        if let i = bridge.doc.sends.lastIndex(where: { $0.result == ShortcutOutcome.Kind.noReply.rawValue }),
           clock.now.timeIntervalSince(bridge.doc.sends[i].at) < 15 * 60 {
            let s = bridge.doc.sends[i]
            var result: String?
            if case .ok(let r) = cb { result = r }
            finishShortcutRun(HealthPendingRun(sendId: s.id, shortcut: s.shortcut, startedAt: s.at, keys: s.keys),
                              ShortcutOutcome.from(cb, shortcut: s.shortcut), result: result, raw: raw)
            return
        }
        if case .error = cb { showNotice("A Shortcut reported an error: \(raw ?? "no details")") }
    }

    /// `quiet`: logged and kept as the page's banner, but no notice and no navigation (a stale run found at launch).
    func finishShortcutRun(_ p: HealthPendingRun, _ outcome: ShortcutOutcome, result: String?, raw: String? = nil,
                           quiet: Bool = false) {
        let b = healthBridge
        b.noReplyTask?.cancel()
        if b.doc.pending?.sendId == p.sendId { b.doc.pending = nil }
        let now = clock.now
        var detail = outcome.kind == .ok ? nil : outcome.message
        if outcome.kind == .ok, p.shortcut == ShortcutNames.healthOut { detail = Self.pcAnswer(result) }
        if let raw { detail = (detail.map { $0 + " · " } ?? "") + "iOS sent: " + raw }
        if let i = b.doc.sends.lastIndex(where: { $0.id == p.sendId }) {
            b.doc.sends[i].result = outcome.kind.rawValue
            b.doc.sends[i].detail = detail
            b.doc.sends[i].resultAt = now
            b.doc.sends[i].raw = raw
        }
        if outcome.kind == .ok {
            for k in p.keys { b.doc.sentKeys[k] = now }
        }
        b.doc.trim()
        b.banner = AppleHealthState.Banner(text: outcome.message, stepsFor: outcome.offerSteps ? p.shortcut : nil,
                                           isProblem: outcome.kind != .ok)
        guard !quiet else { return }
        if outcome.offerSteps {
            showAppleHealthPage()       // the banner's Steps button lives there
        }
        showNotice(outcome.message)
    }

    /// The PC's answer as "Health → HealthApp" returned it (the Shortcut's last action is Get Contents of URL).
    static func pcAnswer(_ result: String?) -> String? {
        guard let text = result, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result.map { "Shortcuts said: \($0.prefix(200))" }
        }
        if obj["status"] as? String == "stored" {
            let days = (obj["days"] as? [String]) ?? []
            return "PC stored \(obj["accepted"] ?? "?") samples (\(obj["import"] ?? "?"))"
                + (days.isEmpty ? "" : ", \(days.first!)…\(days.last!)")
        }
        if obj["status"] as? String == "duplicate" { return "PC already had these samples (\(obj["import"] ?? "?"))." }
        if obj["status"] as? String == "empty" { return "PC got no samples: nothing new in Apple Health." }
        if let reason = obj["reason"] as? String { return "PC refused: \(reason)" }
        return "Shortcuts said: \(text.prefix(200))"
    }

    // MARK: Foreground

    /// Scene became active (AppModel.scenePhaseChanged): a run that never called back is reported after a short wait
    /// (the callback URL may arrive just after); a waiting automatic send runs; waiting import links go to the PC.
    func appleHealthBecameActive() async {
        await bridgeLoad()
        let b = healthBridge
        if let p = b.doc.pending {
            b.noReplyTask?.cancel()
            b.noReplyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, let still = self.healthBridge.doc.pending,
                      still.sendId == p.sendId else { return }
                self.finishShortcutRun(still, .noReply(shortcut: still.shortcut), result: nil)
                await self.bridgeSave()
                await self.publishAppleHealth()
            }
        } else if let day = b.doc.autoWaiting, b.doc.autoSend, !isSample {
            if day == LocalDay(date: clock.now, calendar: calendar).iso {
                await sendTodayToHealth(auto: true)
            } else {
                b.doc.autoWaiting = nil
            }
        }
        if b.doc.imports.contains(where: { $0.status == "waiting" || $0.status == "failed" }) {
            await forwardImports()
        }
        await bridgeSave()
        await publishAppleHealth()
    }

    // MARK: OUT — the token, and the import-link fallback

    func fetchShortcutToken() async {
        let creds: PCCredentials?
        do {
            creds = try KeychainCredentialStore().load()
        } catch {
            healthBridge.token = .failed("\(error)")
            return
        }
        guard let creds else {
            healthBridge.token = .notPaired
            return
        }
        healthBridge.token = .loading
        await publishAppleHealth()
        do {
            let resp = try await URLSessionPCLabTransport().send(
                PCRequest(method: "GET", path: "/v1/shortcut-token", headers: ["Authorization": "Bearer \(creds.deviceKey)"],
                          timeout: 10), baseURL: creds.baseURL)
            let obj = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            guard resp.status == 200, let token = obj?["token"] as? String else {
                let reason = (obj?["reason"] as? String)
                    ?? (resp.status == 404 ? "this PC Lab is older than the Apple Health bridge — restart it with the new code"
                                           : "HTTP \(resp.status)")
                healthBridge.token = .failed(reason)
                return
            }
            var base = creds.baseURL.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            healthBridge.token = .ready(token: token, endpoint: base + ((obj?["path"] as? String) ?? "/v1/health-samples"))
        } catch {
            healthBridge.token = .failed("\(error) — is Tailscale on and the PC awake?")
        }
    }

    func copyForShortcut(_ what: AppleHealthCopy) {
        switch what {
        case .shortcutName(let name):
            UIPasteboard.general.string = name
            showNotice("Copied “\(name)”. Paste it as the Shortcut's name.")
        case .endpoint, .authorization:
            guard case .ready(let token, let endpoint) = healthBridge.token else {
                showNotice("No token yet: pair with your PC Lab, then tap Get token again.")
                return
            }
            if what == .endpoint {
                UIPasteboard.general.string = endpoint
                showNotice("Copied the URL. Paste it into Get Contents of URL.")
            } else {
                UIPasteboard.general.string = "Bearer \(token)"
                showNotice("Copied the header value. Paste it as the Authorization header's value.")
            }
        }
    }

    func importLinkArrived(_ link: ShortcutLink.ImportLink) async {
        switch link {
        case .invalid(let why):
            healthBridge.doc.imports.append(HealthImportRecord(id: UUID(), at: clock.now, bytes: 0, sha8: "", body: nil,
                                                               status: "rejected", detail: why, forwardedAt: nil))
            showNotice(why)
        case .body(let data):
            let sha8 = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
            healthBridge.doc.imports.append(HealthImportRecord(id: UUID(), at: clock.now, bytes: data.count, sha8: sha8,
                                                               body: data, status: "waiting", detail: nil, forwardedAt: nil))
            showNotice("Got \(data.count / 1000) KB of Apple Health samples from Shortcuts — sending them to your PC.")
            await bridgeSave()
            await forwardImports()
        }
        healthBridge.doc.trim()
    }

    /// POST every waiting import to /v1/health-samples with the device key. 201/200 → done (body dropped); 400 → rejected
    /// for good (kept with the reason); anything else → failed, tried again at the next foreground.
    func forwardImports() async {
        let b = healthBridge
        guard !isSample, !b.forwarding else { return }
        b.forwarding = true
        defer { b.forwarding = false }
        guard let creds = try? KeychainCredentialStore().load() else {
            for i in b.doc.imports.indices where b.doc.imports[i].status == "waiting" {
                b.doc.imports[i].detail = "Waiting: not paired with your PC Lab yet."
            }
            return
        }
        let transport = URLSessionPCLabTransport()
        for i in b.doc.imports.indices where ["waiting", "failed"].contains(b.doc.imports[i].status) {
            guard let body = b.doc.imports[i].body else { continue }
            do {
                let resp = try await transport.send(
                    PCRequest(method: "POST", path: "/v1/health-samples",
                              headers: ["Authorization": "Bearer \(creds.deviceKey)", "Content-Type": "application/json"],
                              body: body, timeout: 60), baseURL: creds.baseURL)
                let obj = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
                switch resp.status {
                case 200, 201:
                    b.doc.imports[i].status = resp.status == 201 ? "stored" : "duplicate"
                    b.doc.imports[i].detail = Self.pcAnswer(String(data: resp.body, encoding: .utf8))
                    b.doc.imports[i].body = nil
                    b.doc.imports[i].forwardedAt = clock.now
                case 400, 413:
                    b.doc.imports[i].status = "rejected"
                    b.doc.imports[i].detail = "PC refused: " + ((obj?["reason"] as? String) ?? "HTTP \(resp.status)")
                default:
                    b.doc.imports[i].status = "failed"
                    b.doc.imports[i].detail = "PC answered HTTP \(resp.status): " + ((obj?["reason"] as? String) ?? "")
                }
            } catch {
                b.doc.imports[i].status = "failed"
                b.doc.imports[i].detail = "Not sent (\(error)) — tried again next time the app opens."
            }
        }
        b.doc.trim()
        await bridgeSave()
    }

    // MARK: State

    func publishAppleHealth() async {
        await bridgeLoad()
        let b = healthBridge
        let today = LocalDay(date: clock.now, calendar: calendar)
        var lines: [String] = []
        var skipped: [String] = []
        var nothing: String?
        if !isSample {
            let p = await healthPayload(today)
            lines = p.items.map(\.summary)
            skipped = p.skipped
            if p.json == nil {
                nothing = b.doc.sentKeys.keys.contains(where: { $0.hasSuffix(":" + today.iso) })
                    ? "Today's values are already in Apple Health (a Shortcut can't replace a sample, so they are not sent twice)."
                    : "Nothing for today yet: last night's values come after the morning compute."
            }
        }
        let input = AppleHealthInput(
            now: clock.now, calendar: calendar, sample: isSample, inShortcut: ShortcutNames.healthIn,
            outShortcut: ShortcutNames.healthOut, todayLines: lines, todaySkipped: skipped, nothingToSend: nothing,
            autoSend: b.doc.autoSend, pending: b.doc.pending.map { (shortcut: $0.shortcut, since: $0.startedAt) },
            banner: b.banner, token: b.token,
            sends: b.doc.sends.map { AppleHealthInput.Send(id: $0.id.uuidString, at: $0.at, shortcut: $0.shortcut,
                                                           what: $0.what, result: $0.result, detail: $0.detail,
                                                           auto: $0.auto) },
            imports: b.doc.imports.map { AppleHealthInput.Import(id: $0.id.uuidString, at: $0.at, bytes: $0.bytes,
                                                                 status: $0.status, detail: $0.detail) },
            guides: ShortcutSteps.guides, expanded: b.expanded)
        var made = AppleHealthPresenter.make(input)
        if let auto = services.healthAuto { made.autoLine = await auto.statusLine()
            made.autoTypeLines = await auto.typeRows().map { "\($0.name): \($0.text)" }
        }
        b.state = made
    }

    // MARK: Storage (MGStore kv, one document)

    func bridgeLoad() async {
        let b = healthBridge
        if let t = b.loadTask {
            await t.value
            return
        }
        let t = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.bridgeLoadOnce()
        }
        b.loadTask = t
        await t.value
    }

    private func bridgeLoadOnce() async {
        let b = healthBridge
        if let raw = try? await services.store.value(forKey: HealthBridgeDoc.key) {
            if let doc = try? JSONDecoder().decode(HealthBridgeDoc.self, from: raw) {
                b.doc = doc
            } else {
                // Keep the unreadable bytes under a second key before a fresh document is saved over them.
                try? await services.store.setValue(raw, forKey: HealthBridgeDoc.key + ".unreadable")
                showNotice("The Apple Health log couldn't be read; a new one was started (the old one is kept).")
            }
        }
        // The app was closed while a run was out and nothing ever called back.
        if let p = b.doc.pending, clock.now.timeIntervalSince(p.startedAt) > 10 * 60 {
            finishShortcutRun(p, .noReply(shortcut: p.shortcut), result: nil, quiet: true)
        }
    }

    func bridgeSave() async {
        guard let data = try? JSONEncoder().encode(healthBridge.doc) else { return }
        do {
            try await services.store.setValue(data, forKey: HealthBridgeDoc.key)
        } catch {
            showNotice("The Apple Health log wasn't saved: \(error)")
        }
    }
}
