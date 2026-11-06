import Combine
import Foundation
import MGContext
import MGStore
import MGSync

// Settings › Usage (tracker #40, Mo 2026-10-11: "metrics in the settings for what compute it's using on my phone …
// storage on my phone and desktop … compute desktop used or in use"). Measured when the page opens and on "Measure
// again" — never on a timer: walking the container and summing the raw-frame blobs is itself work.
//   phone: every file in the app container (the database = mg.sqlite + -wal + -shm), what is inside the database
//          (MGStore.storageReport), free space on the iPhone;
//   background: BackgroundRunLog (every BGTask run: start, end, outcome, note, CPU);
//   compute: ProcessUsage (CPU time, memory footprint, wake-ups, thermal state, Low Power Mode);
//   PC: GET /v1/usage (MGSync PCLabUsage), shown with the time it answered, or "PC not reachable" with the reason.
// Read-only throughout: nothing is written, deleted or sent except the one authenticated GET.

/// The page's model: AppModel+Usage fills it; UI/Usage/UsageView.swift observes `state`.
@MainActor
final class UsageModel: ObservableObject {
    @Published var state: UsageState?

    var measuredAt: Date?
    var phone: PhoneStorageInput?
    var phoneProblem: String?
    var process: ProcessUsageSample?
    var pc: PCUsageStatus = .notAsked
    var lastPC: PCUsageInput?
    var refreshing = false
    /// Raw frames waiting (Low Data Mode, #74), from the sync coordinator.
    var rawHeld: String?
}

extension AppModel {
    func usageAction(_ action: UsageAction) async {
        switch action {
        case .open:
            if paths[tab]?.last != .usage { push(.usage) }
            await usageMeasure()
        case .refresh:
            await usageMeasure()
        }
    }

    func usageMeasure() async {
        let u = usage
        guard !u.refreshing else { return }
        u.refreshing = true
        u.pc = .reading
        usagePublish()

        let dbURL = try? MGStore.defaultURL()
        let scan = await Task.detached(priority: .utility) { UsageScan.container(databaseURL: dbURL) }.value
        var phone = scan.input
        var problem = scan.problem
        do {
            let r = try await services.store.storageReport()
            phone?.rawFrameBytes = r.rawFrameBytes
            phone?.rawFrames = r.rawFrames
            phone?.rawFramesUnconfirmed = r.rawFramesUnconfirmed
            phone?.outboxBytes = r.outboxBytes
            phone?.opticalBytes = r.opticalBytes
        } catch {
            problem = [problem, "Inside the database couldn't be measured: \(error)."].compactMap { $0 }
                .joined(separator: " ")
        }
        u.phone = phone
        u.phoneProblem = problem
        u.process = ProcessUsage.sample()
        u.rawHeld = await services.syncCoordinator.rawHeld
        await keepUpMeasure()           // wave W11: history keep-up and raw motion cost
        u.measuredAt = clock.now
        usagePublish()

        switch await PCLabUsage.fetch(credentials: KeychainCredentialStore()) {
        case .report(let r):
            let pc = Self.pcUsageInput(r)
            u.lastPC = pc
            u.pc = .answered(pc)
        case .notPaired:
            u.pc = .notPaired
        case .unreachable(let why):
            u.pc = .notReachable(reason: "\(why); is Tailscale on and the PC awake?", last: u.lastPC)
        case .refused(let why):
            u.pc = .notReachable(reason: why, last: u.lastPC)
        }
        u.refreshing = false
        usagePublish()
    }

    func usagePublish() {
        let u = usage
        var input = UsageInput(now: clock.now, calendar: calendar, sample: isSample, measuredAt: u.measuredAt,
                               phone: u.phone, phoneProblem: u.phoneProblem, runs: BackgroundRunLog.all(),
                               roles: BackgroundTasks.registeredRoles.map(\.rawValue),
                               backgroundProblems: BackgroundTasks.registrationProblems, process: u.process,
                               pc: u.pc, refreshing: u.refreshing)
        input.rawHeld = u.rawHeld
        var s = UsagePresenter.make(input)
        s.sections.append(ActivityUsage.section(tally: ActivityLog.today(), runs: BackgroundRunLog.all(), now: clock.now,
                                                calendar: calendar))      // B-6: what's running today
        s.sections.append(PhoneUseSessions.section(PhoneUseLog.shared.built(calendar: calendar), now: clock.now,
                                                   calendar: calendar))      // T9818: phone use (estimate)
        s.sections.append(ComputeLogUsage.section(lines: ComputeLog.shared.lines(), calendar: calendar))   // T9737
        s.sections.append(keepUpUsageSection())     // wave W11: "Strap in the background"
        if u.state != s { u.state = s }
    }

    static func pcUsageInput(_ r: PCUsageReport) -> PCUsageInput {
        let p = r.running.pipeline
        let g = r.running.plugins
        return PCUsageInput(
            at: r.at, pcName: r.pcName, dataDir: r.storage.dataDir, totalBytes: r.storage.totalBytes,
            areas: r.storage.areas.map { PCUsageInput.Area(id: $0.id, label: $0.label, bytes: $0.bytes, files: $0.files) },
            diskFreeBytes: r.storage.disk?.freeBytes, diskTotalBytes: r.storage.disk?.totalBytes,
            uptimeSeconds: r.process.uptimeSeconds, cpuSeconds: r.process.cpuUserSeconds + r.process.cpuSystemSeconds,
            memoryBytes: r.process.memoryBytes, threads: r.process.threads, currentModel: p?.current?.model,
            currentDate: p?.current?.date, currentSince: p?.current?.since, busy: p?.busy ?? false,
            queuedDates: p?.queuedDates ?? [], models: p?.models, loadErrors: p?.loadErrors ?? [],
            pluginsWatching: g?.watching ?? false, pluginsIntervalSeconds: g?.intervalSeconds,
            pluginsLastCheck: g?.lastCheck, pluginsRunning: g?.running ?? [],
            lastPassLine: p?.lastPassLine)
    }
}

/// The container walk (off the main actor).
enum UsageScan {
    struct Result: Sendable {
        var input: PhoneStorageInput?
        var problem: String?
    }

    static func container(databaseURL: URL?) -> Result {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        func relative(_ url: URL) -> String {
            let p = url.resolvingSymlinksInPath().path
            return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: home, includingPropertiesForKeys: keys, options: [],
                                         errorHandler: { _, _ in true }) else {
            return Result(input: nil, problem: "The app's folder couldn't be read.")
        }
        var files: [UsageFile] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let bytes = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            files.append(UsageFile(path: relative(url), bytes: bytes))
        }
        let volume = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey])
        let db = databaseURL.map(relative) ?? "Library/Application Support/MG/mg.sqlite"
        return Result(input: PhoneStorageInput(files: files, databasePath: db,
                                               deviceFreeBytes: volume?.volumeAvailableCapacityForImportantUsage,
                                               deviceTotalBytes: volume?.volumeTotalCapacity.map(Int64.init)),
                      problem: nil)
    }
}
