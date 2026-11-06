// Fallback 2 for the sleep card (Mo, Nov 6 2026): Apple Health's SleepAnalysis read on the phone itself, so the card does not
// wait for the PC row or a full upload queue. Read-only: one HKSampleQuery, nothing written, nothing sent anywhere. The merge
// into a night is `PhoneAppleSleep.build` (MGDomain, plain Swift, tested on Linux). WRITTEN, NOT COMPILED (the app target is
// built with xtool); the call follows HealthKitLayer's other queries.
#if canImport(HealthKit) && os(iOS)
import Foundation
import HealthKit
import MGDomain

public enum HealthKitSleepRead {
    /// The sleep samples between `start` and `end` written by anything but this app, as `AppleSleepSample`s. Empty when Health is
    /// unavailable or read access was not given (iOS does not say which).
    public static func samples(from start: Date, to end: Date) async -> [AppleSleepSample] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [window, HealthKitSupport.notOwnSource()])
        let store = HKHealthStore()
        return await withCheckedContinuation { (cont: CheckedContinuation<[AppleSleepSample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, _ in
                let out = ((results as? [HKCategorySample]) ?? []).map {
                    AppleSleepSample(value: $0.value, start: $0.startDate, end: $0.endDate,
                                     source: $0.sourceRevision.source.name)
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }
}
#endif
