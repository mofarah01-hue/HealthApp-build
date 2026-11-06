import Foundation
import MGBLE
import MGContext
import MGDomain

// Live › Research › "Test: read history without deleting" (wave W12b, #111/#119; Mo 2026-10-11 ~23:30 PT: "read without
// deleting of course"). MGBLE runs it (StrapLink+HistoryProbe.swift): GET_DATA_RANGE, the first chunk stored but not
// acknowledged, ABORT, GET_DATA_RANGE, the same request again. The result stays on the Live tab until the next run.
extension AppModel {
    static let historyReadTestID = "historyReadTest"

    func runHistoryReadTest() async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked.") }
        guard !historyReadTestRunning else { return }
        historyReadTestRunning = true
        historyReadTestLines = ["Running — about a minute; the normal history download waits until it ends."]
        await refresh()
        let result = await services.strap.runHistoryReadTest()
        historyReadTestRunning = false
        switch result {
        case .success(let r):
            historyReadTestLines = ["Ran at \(Self.clock12(r.endedAt, calendar)) · decoded, untested until you check it"]
                + r.lines
        case .failure(let e):
            historyReadTestLines = ["Not run: \(e.text)"]
        }
        await refresh()
        if research.kind == "decode", research.state != nil { await researchLoad() }   // r9v: the Decode lab shows the result
    }

    /// "11:42 PM".
    nonisolated static func clock12(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0
        return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, c.minute ?? 0, h < 12 ? "AM" : "PM")
    }
}
