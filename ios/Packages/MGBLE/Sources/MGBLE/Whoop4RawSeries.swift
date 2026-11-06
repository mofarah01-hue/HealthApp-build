import Foundation

/// The last hours of WHOOP 4.0 history records for the "Raw 4.0" screen (0.6.0.12): decoded frames, one record per second,
/// oldest first, duplicates removed, and a decimated series per field for the small charts. Pure: the caller hands in raw type-47
/// frames (newest first or any order) from the store.
public struct Whoop4RawSeries: Equatable, Sendable {
    /// Oldest first, one per strap second, only the last `hours` before the newest record.
    public var records: [Whoop4RawRecord]
    /// Frames handed in that were not a v24 record (other versions, other types, short, garbage).
    public var skipped: Int
    /// Frames handed in that decoded.
    public var decoded: Int

    public var latest: Whoop4RawRecord? { records.last }
    public var oldest: Whoop4RawRecord? { records.first }

    /// Decodes `frames`, keeps the last `hours` before the newest record, and drops a second seen twice (a re-sent chunk).
    public static func build(frames: [[UInt8]], hours: Double = 3) -> Whoop4RawSeries {
        var bySecond: [Int: Whoop4RawRecord] = [:]
        var skipped = 0
        var decoded = 0
        for f in frames {
            if let r = Whoop4RawRecord.decode(frame: f) {
                decoded += 1
                bySecond[r.unix] = r
            } else {
                skipped += 1
            }
        }
        let sorted = bySecond.values.sorted { $0.unix < $1.unix }
        guard let newest = sorted.last else { return Whoop4RawSeries(records: [], skipped: skipped, decoded: decoded) }
        let from = newest.unix - Int(hours * 3600)
        return Whoop4RawSeries(records: sorted.filter { $0.unix >= from }, skipped: skipped, decoded: decoded)
    }

    /// One field over time for a chart: at most `maxPoints` (time, value) pairs, each the mean of an equal slice of the records
    /// (a mean, not a pick, so a spike inside a slice is not dropped silently). Empty when there are no records.
    public func series(_ field: Whoop4RawRecord.Field, maxPoints: Int = 240) -> [(at: Date, value: Double)] {
        guard !records.isEmpty, maxPoints > 0 else { return [] }
        let n = records.count
        let size = max(1, Int((Double(n) / Double(maxPoints)).rounded(.up)))
        var out: [(at: Date, value: Double)] = []
        var i = 0
        while i < n {
            let slice = records[i..<min(n, i + size)]
            let mean = slice.map { field.value($0) }.reduce(0, +) / Double(slice.count)
            let t = slice.map { Double($0.unix) }.reduce(0, +) / Double(slice.count)
            out.append((Date(timeIntervalSince1970: t), mean))
            i += size
        }
        return out
    }

    public static func == (a: Whoop4RawSeries, b: Whoop4RawSeries) -> Bool {
        a.records == b.records && a.skipped == b.skipped && a.decoded == b.decoded
    }
}
