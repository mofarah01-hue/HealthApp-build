import Foundation
import MGContext

extension AppModel {
    func appendTestRun(kind: TestRun.Kind, at: Date, result: String, ok: Bool) async {
        testRunLog.append(TestRun(kind: kind, at: at, result: result, ok: ok))
        publishTestRuns()
        do {
            try await services.kv.save(testRunLog, key: TestRunLog.storeKey)
        } catch {
            showNotice("The test run wasn't saved: \(error)")
        }
    }

    func publishTestRuns() {
        testRuns = TestRunsState.make(testRunLog, calendar: calendar)
    }
}
