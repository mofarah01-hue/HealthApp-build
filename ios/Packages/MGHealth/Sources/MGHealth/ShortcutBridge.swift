import Foundation
import MGDomain

// Apple Health through Shortcuts (Mo's decision, 2026-10-11: URL schemes now, not App Intents — xtool cannot make
// Metadata.appintents, xtool issue #145). A free Apple account cannot sign the HealthKit entitlement, so this build never
// touches HealthKit:
//   IN  (app → Apple Health): the app opens the Shortcut "HealthApp → Health" with a JSON text input; the Shortcut logs
//       each value with Log Health Sample.
//   OUT (Apple Health → PC): the Shortcut "Health → HealthApp" runs Find Health Samples and POSTs them to the PC Lab
//       (app/pclab/mglab/shortcut_api.py), or opens healthapp://import?data=… for the app to forward.
// Everything here is plain Swift. Tests: Tests/MGHealthTests/ShortcutBridgeTests.swift (written 2026-10-11, NOT RUN:
// XCTest does not run on Windows / the WSL xtool build; `swift test --package-path app/ios/Packages/MGHealth` on a Mac).
//
// x-callback-url (Apple, "Use x-callback-url with Shortcuts on iPhone or iPad",
// https://support.apple.com/guide/shortcuts/use-x-callback-url-apdcd7f20a6f/ios, read 2026-10-11):
//   - x-success opens when the shortcut finishes; "a parameter named result is appended to the URL and contains the
//     textual output of the shortcut";
//   - x-cancel opens when the user cancels; no output;
//   - x-error opens when it fails; "a parameter named errorMessage is appended to the URL and contains a description of
//     the error".
//   URL form: shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-success=…&x-cancel=…
//   (input = text or clipboard: "Run a shortcut from a URL", support.apple.com/guide/shortcuts/apd624386f42/ios).
// Apple does NOT document what happens when no shortcut has that name. One field report: a Scriptable x-callback call
// whose name Shortcuts did not find came back through x-error as "Could not find the specified shortcut."
// (https://talk.automators.fm/t/calling-a-shortcut-from-a-script-using-the-x-callback-url-protocol/13754). So "not
// found" is recognised by that wording and similar wordings ONLY (changed 2026-10-11: an empty errorMessage used to
// count as "not found" too) — and a run that never calls back at all is reported as "no reply"
// (ShortcutOutcome.noReply) with the same offer of the build steps.
// iOS 26.5+ (Drafts forum, https://forums.getdrafts.com/t/problems-running-shortcuts-on-latest-os-26-5-and-other-updates/16754,
// read 2026-10-11; Apple FB22785648): x-success is never called; x-error arrives with errorCode=4 and
// errorDomain=WFOutOfProcessWorkflowControllerErrorDomain EVEN WHEN THE SHORTCUT RAN. That pair is read as "ran — iOS
// no longer reports results back" (ShortcutOutcome.Kind.unconfirmed). Every callback's raw parameters are kept
// (`ShortcutLink.describe`) so a run on iOS 27 shows what iOS really sends.

/// The three Shortcuts the app runs, by name. Mo names them EXACTLY this (Settings › Apple Health has Copy buttons:
/// the arrow is not on the iPhone keyboard).
public enum ShortcutNames {
    /// IN: logs the app's values into Apple Health.
    public static let healthIn = "HealthApp → Health"
    /// OUT: sends Apple Health samples to the PC Lab.
    public static let healthOut = "Health → HealthApp"
    /// Switches Tailscale on (Tailscale's own Connect action): the Tailscale reminder's Connect button.
    public static let tailscale = "HealthApp Tailscale"

    public static let all = [healthIn, healthOut, tailscale]
}

/// The URLs: running a Shortcut with x-callback-url, and the app's own `healthapp://` links.
public enum ShortcutLink {
    public static let scheme = "healthapp"
    public static let success = "healthapp://shortcut/ok"
    public static let error = "healthapp://shortcut/error"
    public static let cancel = "healthapp://shortcut/cancel"

    /// Percent-encodes everything except RFC 3986 unreserved characters (A-Z a-z 0-9 - . _ ~), as UTF-8. `&`, `=`, `+`,
    /// `#`, `?`, `/`, spaces, quotes and the arrow in the names all become %XX, so a JSON text or a callback URL can
    /// never end the outer query early.
    public static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// `shortcuts://x-callback-url/run-shortcut?name=<name>[&input=text&text=<text>]&x-success=…&x-error=…&x-cancel=…`
    public static func run(_ name: String, text: String? = nil) -> URL? {
        var q = "name=" + encode(name)
        if let text { q += "&input=text&text=" + encode(text) }
        q += "&x-success=" + encode(success) + "&x-error=" + encode(error) + "&x-cancel=" + encode(cancel)
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + q)
    }

    public enum Callback: Equatable, Sendable {
        case ok(result: String?)
        /// x-error's `errorMessage`, `errorCode`, `errorDomain` (the last two: iOS 26.5+, not in Apple's guide).
        case error(message: String?, code: String? = nil, domain: String? = nil)
        case cancel
    }

    /// The domain iOS 26.5+ reports for a run whose result it no longer returns (with errorCode 4).
    public static let lostResultDomain = "WFOutOfProcessWorkflowControllerErrorDomain"
    public static let lostResultCode = "4"

    /// Every parameter of a `healthapp://shortcut/…` callback, raw, for the log: "error · errorCode=4 ·
    /// errorDomain=WFOutOfProcessWorkflowControllerErrorDomain · errorMessage=(none)". nil for any other URL.
    public static func describe(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "shortcut" else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        let kind = (first.split(separator: "&").first.map(String.init) ?? "").lowercased()
        let p = parameters(url)
        let errorKeys = ["errorCode", "errorDomain", "errorMessage"]
        var parts = [kind.isEmpty ? "(no kind)" : kind]
        if kind == "error" {
            for k in errorKeys {
                parts.append("\(k)=" + (p[k].map { $0.isEmpty ? "(empty)" : String($0.prefix(200)) } ?? "(none)"))
            }
        }
        for k in p.keys.sorted() where !errorKeys.contains(k) {
            parts.append("\(k)=" + String((p[k] ?? "").prefix(200)))
        }
        return parts.joined(separator: " · ")
    }

    /// `healthapp://shortcut/{ok|error|cancel}[?result=…|?errorMessage=…]` → the callback; nil for any other URL.
    /// Tolerates a caller that appended its parameter with `&` although the URL had no `?`.
    public static func callback(_ url: URL) -> Callback? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "shortcut" else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        let kind = (first.split(separator: "&").first.map(String.init) ?? "").lowercased()
        let p = parameters(url)
        switch kind {
        case "ok", "success": return .ok(result: p["result"])
        case "error": return .error(message: p["errorMessage"], code: p["errorCode"], domain: p["errorDomain"])
        case "cancel": return .cancel
        default: return nil
        }
    }

    /// What a `healthapp://import?data=…` link carries.
    public enum ImportLink: Equatable, Sendable {
        /// The body to POST to /v1/health-samples: the JSON as given, or plain text lines wrapped as {"lines": …}.
        case body(Data)
        case invalid(String)
    }

    /// `healthapp://import?data=<URL-encoded JSON or "Type | Start | End | Value | Unit | Source" lines>`; nil for any
    /// other URL. Plain lines are wrapped as `{"lines": "<text>"}` (a raw newline inside a JSON string is not JSON, so a
    /// Shortcut cannot easily build the JSON itself).
    public static func importLink(_ url: URL) -> ImportLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "import" else { return nil }
        guard let text = parameters(url)["data"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("The link has no data. It must look like healthapp://import?data=<URL-encoded text>.")
        }
        let data = Data(text.utf8)
        if let obj = try? JSONSerialization.jsonObject(with: data), obj is [Any] || obj is [String: Any] {
            return .body(data)
        }
        guard let wrapped = try? JSONSerialization.data(withJSONObject: ["lines": text], options: [.sortedKeys]) else {
            return .invalid("The link's data could not be read.")
        }
        return .body(wrapped)
    }

    /// Query parameters, percent-decoded. A `+` is kept as `+` (it is part of "+05:30" in a date).
    static func parameters(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var raw = comps.percentEncodedQuery ?? ""
        if let amp = comps.percentEncodedPath.firstIndex(of: "&") {
            let tail = String(comps.percentEncodedPath[comps.percentEncodedPath.index(after: amp)...])
            raw = raw.isEmpty ? tail : tail + "&" + raw
        }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            if out[key] == nil { out[key] = value }
        }
        return out
    }
}

/// What the app tells Mo after a Shortcut run.
public struct ShortcutOutcome: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `unconfirmed`: iOS 26.5+ ran it but reported errorCode 4 instead of the result (nothing marked as sent).
        case ok, notFound, failed, cancelled, noReply, couldNotOpen, unconfirmed
    }

    public var kind: Kind
    public var message: String
    /// Show the "Steps" button (the build steps for this shortcut).
    public var offerSteps: Bool

    public init(kind: Kind, message: String, offerSteps: Bool) {
        self.kind = kind
        self.message = message
        self.offerSteps = offerSteps
    }

    /// The callback → what to say. Only a message that reads like a missing shortcut is "not found"; errorCode 4 in
    /// WFOutOfProcessWorkflowControllerErrorDomain (iOS 26.5+) is "ran, unconfirmed"; any other x-error is "failed".
    public static func from(_ callback: ShortcutLink.Callback, shortcut: String) -> ShortcutOutcome {
        switch callback {
        case .ok(let result):
            let r = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ShortcutOutcome(kind: .ok, message: "“\(shortcut)” ran." + (r.isEmpty ? "" : " It said: \(r.prefix(200))"),
                                   offerSteps: false)
        case .error(let message, let code, let domain):
            if isNotFound(message) {
                return ShortcutOutcome(kind: .notFound, message: "Shortcut “\(shortcut)” not found — build it (steps)",
                                       offerSteps: true)
            }
            if isLostResult(code: code, domain: domain) {
                return ShortcutOutcome(kind: .unconfirmed,
                                       message: "“\(shortcut)” ran — iOS no longer reports results back (errorCode 4), "
                                           + "so this is unconfirmed. Check Apple Health; nothing is marked as sent.",
                                       offerSteps: false)
            }
            let m = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let codeText = [code.map { "code \($0)" }, domain].compactMap { $0 }.joined(separator: ", ")
            let what = m.isEmpty ? "no message" + (codeText.isEmpty ? "" : " (\(codeText))") : String(m.prefix(300))
            return ShortcutOutcome(kind: .failed, message: "Shortcut “\(shortcut)” stopped with an error: \(what)",
                                   offerSteps: true)
        case .cancel:
            return ShortcutOutcome(kind: .cancelled, message: "“\(shortcut)” was cancelled — nothing is marked as sent.",
                                   offerSteps: false)
        }
    }

    /// Mo came back to the app and Shortcuts never called back (Shortcuts showed an alert, or he switched apps).
    public static func noReply(shortcut: String) -> ShortcutOutcome {
        ShortcutOutcome(kind: .noReply, message: "Shortcuts didn't report back for “\(shortcut)”. If it said the shortcut "
                        + "wasn't found, build it (steps). Nothing is marked as sent.", offerSteps: true)
    }

    public static func couldNotOpen(shortcut: String) -> ShortcutOutcome {
        ShortcutOutcome(kind: .couldNotOpen, message: "Couldn't open Shortcuts to run “\(shortcut)”. Is the Shortcuts app "
                        + "installed?", offerSteps: false)
    }

    /// True only for the wordings of a missing shortcut ("Could not find the specified shortcut."); an empty or absent
    /// message is NOT "not found" (2026-10-11: iOS 26.5+ sends x-error without the result for runs that worked).
    public static func isNotFound(_ message: String?) -> Bool {
        guard let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return false }
        let l = m.lowercased().replacingOccurrences(of: "’", with: "'")
        if l.contains("not found") || l.contains("could not find") || l.contains("couldn't find")
            || l.contains("does not exist") || l.contains("doesn't exist") || l.contains("no shortcut") {
            return true
        }
        return l.contains("find") && l.contains("shortcut")
    }

    /// iOS 26.5+: errorCode 4 in WFOutOfProcessWorkflowControllerErrorDomain = the shortcut ran, its result was lost.
    public static func isLostResult(code: String?, domain: String?) -> Bool {
        code?.trimmingCharacters(in: .whitespaces) == ShortcutLink.lostResultCode
            && domain?.trimmingCharacters(in: .whitespaces) == ShortcutLink.lostResultDomain
    }
}

/// "Test ‘HealthApp → Health’ (sends nothing)" (2026-10-11): the Shortcut's steps log only keys that have a value, and
/// this has none, so a run exercises "not found" and the callback without writing anything to Apple Health.
public enum ShortcutTestPayload {
    public static let text = #"{"v":1,"app":"HealthApp","test":true,"samples":[]}"#
}

/// The JSON the app hands "HealthApp → Health" for one day, built ONLY from the Mirror's rules (Mirror.swift: D12,
/// `MirrorPlanner` + `MirrorPolicy`): measured or directly derived values, tiers verified / strap / high, never breathing
/// rate, SpO₂, skin temperature, sleep stages or scores. Three of the mirror's six types go through this Shortcut (the
/// ones Log Health Sample can take as one value a day):
///
/// | app metric (registry name)        | JSON keys                         | Log Health Sample type  | unit       |
/// |-----------------------------------|-----------------------------------|-------------------------|------------|
/// | `rhr` (own variants)              | `rhr`, `rhr_unit`, `rhr_date`     | Resting Heart Rate      | count/min  |
/// | `hrv_sdnn` ONLY (never RMSSD)     | `hrv_sdnn`, `hrv_sdnn_unit`, `_date` | Heart Rate Variability | ms (SDNN)  |
/// | `sleep_onset` + `wake_time`       | `sleep_start`, `sleep_end`        | Sleep Analysis, Asleep  | —          |
///
/// HealthKit's HRV type is SDNN (HKQuantityTypeIdentifierHeartRateVariabilitySDNN), so `hrv_rmssd` / `hrv_ln_rmssd` are
/// never sent under it. The strap's SpO₂ byte is a raw count, never a %, and is never sent. Imported history (variants
/// `apple_health` / `whoop_export`, producer `apple` / `vendor_import`) is never sent back. Per-minute heart rate,
/// caffeine and workouts stay out of this Shortcut (hundreds of samples a day do not fit a URL or a Shortcut loop; the
/// other two need a loop) — `skipped` says so when they exist.
public struct ShortcutHealthPayload: Sendable {
    public struct Item: Equatable, Sendable {
        /// `mgapp:<metric>:<day>` (MirrorSample.externalKey): the app remembers which were logged, so a day is never
        /// logged twice (a Shortcut cannot replace a Health sample).
        public var key: String
        public var healthType: String
        /// "Resting HR 52 bpm → Resting Heart Rate".
        public var summary: String
    }

    public var day: LocalDay
    public var items: [Item]
    /// One line per value that exists but is not sent, with the reason.
    public var skipped: [String]
    /// UTF-8 JSON for the Shortcut's text input; nil when there is nothing to send.
    public var json: Data?
    public var jsonText: String? { json.flatMap { String(data: $0, encoding: .utf8) } }

    static let importVariants: Set<String> = ["apple_health", "whoop_export", "apple"]

    /// The app's own value of `name` for the day: not imported history, a value present, the primary one first.
    static func own(_ metrics: [Metric], _ name: String) -> Metric? {
        let mine = metrics.filter { m in
            m.name == name && m.value != nil && !ImportedHistory.isImported(m)
                && m.producer != .apple && m.producer != .vendorImport
                && !importVariants.contains(m.variant ?? "")
        }
        return mine.first { $0.primary == true } ?? mine.first
    }

    public static func build(day: LocalDay, metrics: [Metric], timeZone: TimeZone, sentKeys: Set<String> = [],
                             device: MirrorDevice = MirrorDevice()) -> ShortcutHealthPayload {
        let planner = MirrorPlanner(device: device)
        var planned: [(field: String, sample: MirrorSample, healthType: String, summary: String)] = []
        var skipped: [String] = []
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        func hm(_ d: Date) -> String { ClockText.hm(d, timeZone: cal.timeZone) }      // 12-hour (W10)

        if let m = own(metrics, MetricKey.rhr.rawValue), let v = m.value,
           let s = planner.restingHeartRate(MirrorDailyValue(value: v, at: m.at, tier: m.tier, method: m.method), day: day) {
            planned.append(("rhr", s, "Resting Heart Rate", "Resting HR \(fmt(v)) bpm → Resting Heart Rate"))
        }
        if let m = own(metrics, MetricKey.hrvSdnn.rawValue), let v = m.value,
           let s = planner.hrvSDNN(MirrorDailyValue(value: v, at: m.at, tier: m.tier, method: m.method), day: day) {
            planned.append(("hrv_sdnn", s, "Heart Rate Variability", "HRV (SDNN) \(fmt(v)) ms → Heart Rate Variability"))
        } else if own(metrics, MetricKey.hrvRmssd.rawValue) != nil {
            skipped.append("HRV: only RMSSD today. Apple Health's HRV is SDNN, so RMSSD is not sent.")
        }
        if let on = own(metrics, MetricKey.sleepOnset.rawValue), let wk = own(metrics, MetricKey.wakeTime.rawValue),
           let a = on.value, let b = wk.value, b > a,
           let s = planner.sleep(MirrorSleepWindow(onset: Date(timeIntervalSince1970: a), wake: Date(timeIntervalSince1970: b),
                                                   tier: wk.tier, method: wk.method), day: day) {
            planned.append(("sleep", s, "Sleep Analysis",
                            "Asleep \(hm(s.start))–\(hm(s.end)) → Sleep Analysis (no stages)"))
        }
        for name in [MetricKey.spo2StrapMean.rawValue, MetricKey.respRate.rawValue, MetricKey.skinTempDev.rawValue]
        where own(metrics, name) != nil {
            skipped.append("\(name): never sent to Apple Health (raw strap counts or an estimate — D12).")
        }

        var dict: [String: Any] = ["v": 1, "app": "HealthApp", "day": day.iso]
        var samples: [[String: Any]] = []
        var items: [Item] = []
        for p in planned {
            do {
                try MirrorPolicy.check(p.sample)
            } catch {
                skipped.append("\(p.healthType): \(error)")
                continue
            }
            if sentKeys.contains(p.sample.externalKey) {
                skipped.append("\(p.healthType): already logged in Apple Health for \(day.iso).")
                continue
            }
            var sample: [String: Any] = ["key": p.sample.externalKey, "hk_type": p.sample.metric.hkIdentifier,
                                         "health_type": p.healthType, "start": iso.string(from: p.sample.start),
                                         "end": iso.string(from: p.sample.end), "tier": p.sample.tier.rawValue]
            if let method = p.sample.method { sample["method"] = method }
            switch p.sample.payload {
            case .quantity(let value, let unit):
                let d = decimal(value)
                dict[p.field] = d
                dict[p.field + "_unit"] = unit
                dict[p.field + "_date"] = iso.string(from: p.sample.start)
                sample["value"] = d
                sample["unit"] = unit
            case .category:
                dict["sleep_start"] = iso.string(from: p.sample.start)
                dict["sleep_end"] = iso.string(from: p.sample.end)
                dict["sleep_value"] = "Asleep"
                sample["value"] = "asleepUnspecified"
            case .workout:
                continue
            }
            samples.append(sample)
            items.append(Item(key: p.sample.externalKey, healthType: p.healthType, summary: p.summary))
        }
        guard !items.isEmpty else {
            return ShortcutHealthPayload(day: day, items: [], skipped: skipped, json: nil)
        }
        dict["samples"] = samples
        let json = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return ShortcutHealthPayload(day: day, items: items, skipped: skipped, json: json)
    }

    /// One decimal, as a Decimal so JSONSerialization writes 41.3, never 41.299999999999997.
    static func decimal(_ v: Double) -> Decimal {
        Decimal(string: String(format: "%.1f", v), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(v)
    }

    static func fmt(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}
