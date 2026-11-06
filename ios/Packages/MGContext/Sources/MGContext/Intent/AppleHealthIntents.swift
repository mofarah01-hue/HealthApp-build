import Foundation

/// Settings › Apple Health — the Shortcuts bridge (added 2026-10-11 for Mo's decision "URL schemes now, not App
/// Intents"). Every tap on that page is one of these, sent as `UIIntent.appleHealth(_:)`.
public enum AppleHealthAction: Equatable, Sendable {
    /// Settings › Apple Health row: push the page.
    case open
    /// "Send today to Health": runs the Shortcut "HealthApp → Health" with today's values.
    case sendToday
    /// Send automatically once the morning compute has today's values.
    case setAutoSend(Bool)
    /// Fetch the Shortcuts token from the PC Lab again.
    case refreshToken
    case copy(AppleHealthCopy)
    /// Open or close one guide's build steps (id = the Shortcut's name, or `AppleHealthState.automationGuideId`).
    case toggleSteps(String)
    /// The banner's "Steps" button: that Shortcut's steps, opened.
    case showSteps(String)
    /// Run a Shortcut by name with no input ("Health → HealthApp", "HealthApp Tailscale") — to build and test it.
    case runShortcut(String)
    /// "Test ‘HealthApp → Health’ (sends nothing)" (2026-10-11): runs it with a payload that has no value to log, so
    /// "not found" and the x-callback reply can be tested on a day with nothing to send.
    case testInShortcut
    /// Send the `healthapp://import` links that are still waiting to the PC Lab.
    case forwardImports
    case dismissBanner
}

/// What a Copy button puts on the clipboard.
public enum AppleHealthCopy: Equatable, Sendable {
    case shortcutName(String)
    /// `<PC base URL>/v1/health-samples`.
    case endpoint
    /// `Bearer <Shortcuts token>` — the whole Authorization header value.
    case authorization
}
