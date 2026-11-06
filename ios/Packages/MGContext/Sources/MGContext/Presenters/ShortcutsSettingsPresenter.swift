import Foundation

/// One App Intent that can be picked as the action in a personal Shortcuts automation.
public struct ShortcutAutomationGuide: Equatable, Sendable, Identifiable {
    public var name: String
    public var parameters: String?

    public init(name: String, parameters: String? = nil) {
        self.name = name
        self.parameters = parameters
    }

    public var id: String { name }

    public var steps: [String] {
        var out = [
            "Open Shortcuts, tap Automation, tap +, then choose when this should run.",
            "Tap Add Action, search for MG, then choose \u{201c}\(name)\u{201d}.",
        ]
        if let parameters {
            out.append("Set \(parameters).")
        } else {
            out.append("This action has no options to fill in.")
        }
        out.append("Tap Next or Add. Turn off Ask Before Running; if iOS offers Run Immediately instead, choose it.")
        out.append("Tap Done.")
        return out
    }
}

/// Settings copy for the App Intents declared in `ios/App/Intents`.
public enum ShortcutsSettingsPresenter {
    public static let installNote = "iOS does not let MG create an automation for you. Pick an action below, then "
        + "tap Add and turn off Ask Before Running in Shortcuts."

    public static let guides: [ShortcutAutomationGuide] = [
        ShortcutAutomationGuide(name: "Log a vape hit"),
        ShortcutAutomationGuide(name: "Start a drink", parameters: "Drink"),
        ShortcutAutomationGuide(name: "Finish my drink"),
        ShortcutAutomationGuide(name: "Log a medication dose", parameters: "Medication"),
        ShortcutAutomationGuide(name: "Log a symptom", parameters: "Symptom and, if wanted, Severity (0\u{2013}3)"),
        ShortcutAutomationGuide(name: "Log how sleepy I am", parameters: "Sleepiness (1\u{2013}9)"),
        ShortcutAutomationGuide(name: "Start a nap", parameters: "Minutes"),
        ShortcutAutomationGuide(name: "Add a note", parameters: "Note"),
        ShortcutAutomationGuide(name: "Sync with my PC"),
        ShortcutAutomationGuide(name: "Start a timer", parameters: "Length and Strap pulses"),
    ]

    public static let updateCheck = "Automations usually keep working after an app update. After updating, run each "
        + "one once. Rebuild it only if Shortcuts says its MG action is unavailable, or if that intent's name or "
        + "parameters changed."
}
