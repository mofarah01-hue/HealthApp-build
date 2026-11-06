import AppIntents
import Foundation
import MGContext

// Timers by voice (T153). One intent, `StartTimerIntent`, that starts a timer: an iPhone alert at the end AND one strap
// buzz (default 4 pulses, 1-8). It runs in the app's process without opening the app (like the other intents).
//
// What Siri can say (the 10th AppShortcut line, added in IntentsAppIntents.swift):
//   "Start a 10 minute timer in <app name>"   - length is an AppEnum in the phrase, so Siri hears it
//   "Start a timer in <app name>"             - Siri asks "How long?" and shows the list
// Apple's own "Hey Siri, set a timer for 10 minutes" goes to the Clock app and cannot be intercepted.

enum TimersLength: String, AppEnum {
    case m1, m2, m3, m5, m10, m15, m20, m25, m30, m45, m60, m90, m120

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Timer length"
    static var caseDisplayRepresentations: [TimersLength: DisplayRepresentation] = [
        .m1: "1 minute", .m2: "2 minutes", .m3: "3 minutes", .m5: "5 minutes", .m10: "10 minutes",
        .m15: "15 minutes", .m20: "20 minutes", .m25: "25 minutes", .m30: "30 minutes", .m45: "45 minutes",
        .m60: "1 hour", .m90: "90 minutes", .m120: "2 hours",
    ]

    var minutes: Int {
        switch self {
        case .m1: return 1
        case .m2: return 2
        case .m3: return 3
        case .m5: return 5
        case .m10: return 10
        case .m15: return 15
        case .m20: return 20
        case .m25: return 25
        case .m30: return 30
        case .m45: return 45
        case .m60: return 60
        case .m90: return 90
        case .m120: return 120
        }
    }
}

struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a timer"
    static var description = IntentDescription("Starts a timer: the iPhone alerts when it ends and the strap buzzes once.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Length")
    var length: TimersLength

    @Parameter(title: "Strap pulses", default: 4)
    var pulses: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard TimerPulses.range.contains(pulses) else {
            throw IntentsError.outOfRange("The strap can buzz 1 to 8 pulses.")
        }
        let minutes = length.minutes
        let said = await TimersController.shared.apply(.start(minutes: minutes, stop: .buzzes(pulses), label: ""))
        return .result(dialog: "\(said ?? "Timer not set.")")
    }
}

// The Siri phrases are the 10th (last allowed) entry of `IntentsShortcuts.appShortcuts` in App/Intents/IntentsAppIntents.swift.
