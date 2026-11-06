import Combine
import Foundation
import MGDomain

/// A `StrapLinking` with no radio, for SwiftUI previews and sample mode (ARCHITECTURE §4.2). It shows whatever
/// state and info it is given and never produces data: streams finish at once, history downloads nothing, and
/// every strap write is refused — so a preview can never pass for a real strap.
@MainActor
public final class MockStrapLink: ObservableObject, StrapLinking {
    @Published public var state: StrapLinkState
    @Published public var info: StrapInfo?

    public init(state: StrapLinkState = .idle, info: StrapInfo? = nil) {
        self.state = state
        self.info = info
    }

    public var liveBeats: AsyncStream<LiveBeat> { AsyncStream { $0.finish() } }
    public var strapEvents: AsyncStream<StrapEvent> { AsyncStream { $0.finish() } }
    public var liveMotion: AsyncStream<StrapMotionSecond> { AsyncStream { $0.finish() } }

    public func start() {}
    public func disconnect() { state = .idle }
    public func reevaluate() {}
    public func setRealtime(hr: Bool, motion: Bool) async throws {}

    public func downloadHistory() async throws -> HistorySummary {
        let now = Date()
        return HistorySummary(startedAt: now, endedAt: now, chunksStored: 0, chunksAcked: 0, duplicateChunks: 0,
                              recordsInserted: 0, endReason: .complete, firstTs: nil, lastTs: nil)
    }

    public func prepareUnlock() async throws -> StrapWritePlan {
        throw StrapLinkError.notReady("preview strap")
    }

    public func runUnlock(_ plan: StrapWritePlan) async throws -> UnlockReport {
        throw StrapLinkError.refusedByPolicy(reason: "preview strap")
    }

    public func restoreUnlock() async throws -> UnlockReport {
        throw StrapLinkError.refusedByPolicy(reason: "preview strap")
    }
}
