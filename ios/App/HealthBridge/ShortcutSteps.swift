import Foundation
import MGContext
import MGHealth

// Tap-by-tap build steps for the three Shortcuts and the daily automation, shown on Settings › Apple Health (one
// expandable guide each). The same steps, with the reasons and the JSON formats, are in app/docs/SHORTCUTS.md — change
// both together. Written 2026-10-11 for iOS 27 Shortcuts from Apple's action names (Get Dictionary from Input, Get
// Dictionary Value, If, Log Health Sample, Find Health Samples, Add to Variable, Repeat with Each, Text, Get Contents of
// URL); the exact place of a button can differ between iOS versions — the action names do not.

enum ShortcutSteps {
    static let guides: [AppleHealthInput.GuideText] = [
        AppleHealthInput.GuideText(
            id: ShortcutNames.healthIn, title: ShortcutNames.healthIn,
            purpose: "Logs today's resting HR, HRV (SDNN) and sleep into Apple Health. “Send today to Health” runs it.",
            steps: [
                "Tap Copy name below. Open Shortcuts › Shortcuts tab › + (top right).",
                "Tap the name at the top › Rename › paste › Done.",
                "Search actions: Get Dictionary from Input. Tap it. It must read “from Shortcut Input” (if not, tap the "
                    + "blue word › Shortcut Input). If Shortcuts asks what the shortcut receives, choose Text.",
                "Add Get Dictionary Value. Tap Key › type rhr. It reads “Get Value for rhr in Dictionary”.",
                "Add If. Tap Condition › has any value (it reads “If Dictionary Value has any value”).",
                "Add Log Health Sample and drag it up, between If and Otherwise. Type › Resting Heart Rate. "
                    + "Value › Select Variable › Dictionary Value. Leave the date.",
                "Below End If: add Get Dictionary Value, Key hrv_sdnn. Tap its blue input (it shows If Result) › "
                    + "Select Variable › Dictionary (from step 3).",
                "Add If › has any value. Inside it, Log Health Sample: Type › Heart Rate Variability, Value › "
                    + "Dictionary Value (the hrv_sdnn one).",
                "Below the second End If: Get Dictionary Value, Key sleep_start, input Dictionary. Add If › has any value.",
                "Inside that If: Get Dictionary Value, Key sleep_end, input Dictionary. Then Log Health Sample: Type › "
                    + "Sleep Analysis, Value › Asleep, Start Date › the sleep_start Dictionary Value, End Date › the "
                    + "sleep_end Dictionary Value. (No Sleep Analysis in the Type list? Skip steps 9–10.)",
                "Tap Done. Test it: back here, tap Send today to Health. Then Health app › Browse › Heart › Resting "
                    + "Heart Rate › Show All Data: today's value, source Shortcuts.",
            ],
            isShortcut: true, runnable: false),
        AppleHealthInput.GuideText(
            id: ShortcutNames.healthOut, title: ShortcutNames.healthOut,
            purpose: "Sends the last 2 days of Apple Health to your PC Lab over Tailscale. Needs the URL and token "
                + "above (Copy buttons).",
            steps: [
                "Tap Copy name below. Shortcuts › + › tap the name › Rename › paste › Done.",
                "Add Find Health Samples. Type › Steps. Add Filter › Start Date › is in the last › 2 days. "
                    + "Group By › Hour (one line per hour instead of hundreds).",
                "Add Add to Variable. Variable Name › type Samples.",
                "Add Find Health Samples, Type › Resting Heart Rate, Add Filter › Start Date is in the last 2 days. "
                    + "Then Add to Variable › Samples.",
                "Do the same (Find Health Samples, 2-day filter, Add to Variable › Samples) for Heart Rate "
                    + "Variability, Sleep Analysis, Weight and Time in Daylight (no Group By). More types work too "
                    + "(Blood Pressure Systolic / "
                    + "Diastolic, VO2 Max, Respiratory Rate).",
                "Add Repeat with Each. Tap its input › Select Variable › Samples.",
                "Inside the repeat add Text. Build this line, putting Repeat Item (above the keyboard) in each "
                    + "[ ] and tapping each inserted Repeat Item to pick the detail: "
                    + "[Type] | [Start Date] | [End Date] | [Value] | [Unit] | [Source]",
                "Tap the Start Date item › Date Format › ISO 8601 › turn on Include ISO 8601 Time. Same for End Date.",
                "Below End Repeat add Get Contents of URL. URL › paste (Copy URL above). Show More: Method › POST. "
                    + "Headers › Add new header: Key Authorization, Value › paste (Copy header above).",
                "Request Body › JSON › Add new field › Text. Key lines, Value › Select Variable › Repeat Results.",
                "Tap Done. Test it: back here, tap Run “Health → HealthApp” now. The log below shows what the PC "
                    + "stored; the file is in data/imports/apple_health_shortcut/ on the PC.",
                "No network? Instead of step 9–10: Combine Text (Repeat Results, New Lines) › URL Encode › Open URLs "
                    + "with healthapp://import?data= followed by the URL Encoded Text. The app sends it to the PC "
                    + "when it can.",
            ],
            isShortcut: true, runnable: false),
        AppleHealthInput.GuideText(
            id: ShortcutNames.tailscale, title: ShortcutNames.tailscale,
            purpose: "Switches Tailscale on, so the phone can reach your PC. The Tailscale reminder's Connect "
                + "button runs it.",
            steps: [
                "Tap Copy name below. Shortcuts › + › tap the name › Rename › paste › Done.",
                "Search actions: Tailscale › Connect (Tailscale's own action; it may be called Turn On VPN).",
                "Tap Done. Test it: Run it now, below.",
            ],
            isShortcut: true, runnable: true),
        AppleHealthInput.GuideText(
            id: AppleHealthState.automationGuideId, title: "Daily automation",
            purpose: "Runs “\(ShortcutNames.healthOut)” every day by itself.",
            steps: [
                "Shortcuts › Automation tab › + › Time of Day.",
                "Pick a time you are usually up and using the phone (e.g. 9:30 AM) › Daily.",
                "Choose Run Immediately (Notify When Run can stay off) › Next.",
                "Pick “\(ShortcutNames.healthOut)” › Done.",
                "Apple Health can't be read while the iPhone is locked: if it was locked at that time the run fails, "
                    + "and the next day's run (2 days back) catches up.",
            ],
            isShortcut: false, runnable: false),
    ]
}
