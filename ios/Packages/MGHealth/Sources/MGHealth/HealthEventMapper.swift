import CryptoKit
import Foundation
import MGDomain

/// Apple Health samples -> contract events (ARCHITECTURE.md 4.10 "Read"):
/// - a blood-pressure correlation with both halves -> one `bp_cuff` event (systolic, diastolic, `cuff_model` from the
///   device, `origin` = source app + device);
/// - everything else -> a `healthkit` event (`hk_type`, `value`, `unit`, `end`, metadata), `origin.app` = the source's
///   name, `origin.device` = the HKDevice;
/// - heart rate, steps and active energy -> one `healthkit` event per hour and source (`HealthReadType.granularity`).
///
/// Event ids are derived from the Health sample's uuid (or the hour), never random: reading the same sample again, after
/// a lost anchor or a reinstall, produces the same id and the same content, and `HealthSampleSink.ingest` then changes
/// nothing (no duplicate, no revision bump).
public struct HealthEventMapper: Sendable {
    public init() {}

    public struct Mapped: Sendable, Equatable {
        public var events: [EventRecord]
        /// Samples left out because their value is not a finite number (they would break the JSON and mean nothing).
        public var skippedInvalid: Int
    }

    public static func stableID(_ key: String) -> UUID {
        var h = Array(SHA256.hash(data: Data(("mgapp-hk:" + key).utf8)).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x50          // version 5 (name based)
        h[8] = (h[8] & 0x3F) | 0x80          // RFC 4122 variant
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    /// The event id for a per-sample event (also what a deleted Health object maps to).
    public static func eventID(forSample uuid: UUID) -> UUID {
        stableID("sample:" + uuid.uuidString.lowercased())
    }

    public func map(_ records: [HealthSampleRecord], loggedAt: Date) -> Mapped {
        var events: [EventRecord] = []
        var skipped = 0
        var groups: [AggregateKey: [HealthSampleRecord]] = [:]
        for r in records {
            switch r.type.granularity {
            case .perSample:
                let out = perSample(r, loggedAt: loggedAt)
                if out.isEmpty { skipped += 1 }
                events += out
            case .hourlyMean, .hourlySum:
                guard case .quantity(let v) = r.value, v.isFinite else { skipped += 1; continue }
                groups[AggregateKey(type: r.type, source: r.source.bundleId ?? r.source.name,
                                    hour: Int64((r.start.timeIntervalSince1970 / 3600).rounded(.down))), default: []].append(r)
            }
        }
        for (key, group) in groups {
            events.append(aggregate(key, group, loggedAt: loggedAt))
        }
        events.sort { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        return Mapped(events: events, skippedInvalid: skipped)
    }

    // MARK: per sample

    private func perSample(_ r: HealthSampleRecord, loggedAt: Date) -> [EventRecord] {
        let origin = Origin(app: r.source.name, device: r.device?.originLabel)
        let base = baseMetadata(r)
        func event(_ idKey: String, hkType: String, value: NumberOrString?, unit: String?, extra: [String: JSONValue] = [:]) -> EventRecord {
            var meta = base
            for (k, v) in extra { meta[k] = v }
            let end: Date? = r.end > r.start ? r.end : nil
            return EventRecord(
                id: HealthEventMapper.stableID(idKey), at: r.start, loggedAt: loggedAt, source: .healthkit, origin: origin,
                payload: .healthkit(HealthKitSampleFields(hkType: hkType, value: value, unit: unit, end: end, metadata: meta)))
        }
        let key = "sample:" + r.uuid.uuidString.lowercased()

        switch r.value {
        case .bloodPressure(let systolic, let diastolic):
            if let s = systolic, let d = diastolic {
                guard s.isFinite, d.isFinite else { return [] }
                let model = r.device?.model ?? r.device?.name
                return [EventRecord(
                    id: HealthEventMapper.stableID(key), at: r.start, loggedAt: loggedAt, source: .healthkit, origin: origin,
                    payload: .bpCuff(BPCuffFields(systolic: s, diastolic: d, cuffModel: model)))]
            }
            // A correlation that lost one half: keep what exists as a plain Health event, never invent the other.
            var out: [EventRecord] = []
            if let s = systolic, s.isFinite {
                out.append(event(key + ":systolic", hkType: HealthReadType.systolicIdentifier, value: .number(s), unit: "mmHg"))
            }
            if let d = diastolic, d.isFinite {
                out.append(event(key + ":diastolic", hkType: HealthReadType.diastolicIdentifier, value: .number(d), unit: "mmHg"))
            }
            return out
        case .quantity(let v):
            guard v.isFinite else { return [] }
            return [event(key, hkType: r.type.rawValue, value: .number(v), unit: r.type.unit?.label)]
        case .category(let code, let name):
            return [event(key, hkType: r.type.rawValue, value: .string(name), unit: nil,
                          extra: ["category_value": .number(Double(code))])]
        case .workout(let w):
            var extra: [String: JSONValue] = ["duration_s": .number(w.durationSeconds)]
            if let e = w.energyKcal, e.isFinite { extra["energy_kcal"] = .number(e) }
            if let d = w.distanceMeters, d.isFinite { extra["distance_m"] = .number(d) }
            return [event(key, hkType: r.type.rawValue, value: .string(w.activity), unit: nil, extra: extra)]
        case .ecg(let e):
            var extra: [String: JSONValue] = [:]
            if let hr = e.averageHeartRate, hr.isFinite { extra["average_hr"] = .number(hr) }
            if let f = e.samplingFrequencyHz, f.isFinite { extra["sampling_hz"] = .number(f) }
            if let s = e.symptomsStatus { extra["symptoms"] = .string(s) }
            return [event(key, hkType: r.type.rawValue, value: .string(e.classification), unit: nil, extra: extra)]
        }
    }

    private func baseMetadata(_ r: HealthSampleRecord) -> [String: JSONValue] {
        var m: [String: JSONValue] = ["hk_uuid": .string(r.uuid.uuidString.lowercased())]
        if let b = r.source.bundleId { m["source_bundle"] = .string(b) }
        if let d = r.device {
            if let v = d.manufacturer { m["device_manufacturer"] = .string(v) }
            if let v = d.model { m["device_model"] = .string(v) }
            if let v = d.hardwareVersion { m["device_hardware"] = .string(v) }
            if let v = d.firmwareVersion { m["device_firmware"] = .string(v) }
            if let v = d.softwareVersion { m["device_software"] = .string(v) }
        }
        if !r.metadata.isEmpty { m["hk_metadata"] = .object(r.metadata.mapValues { JSONValue.string($0) }) }
        return m
    }

    // MARK: hourly summaries

    private struct AggregateKey: Hashable {
        var type: HealthReadType
        var source: String
        var hour: Int64
    }

    private func aggregate(_ key: AggregateKey, _ group: [HealthSampleRecord], loggedAt: Date) -> EventRecord {
        let values: [Double] = group.compactMap { if case .quantity(let v) = $0.value { return v } else { return nil } }
        let isMean = key.type.granularity == .hourlyMean
        let total = values.reduce(0, +)
        let result = isMean ? total / Double(values.count) : total
        let start = Date(timeIntervalSince1970: Double(key.hour) * 3600)
        let first = group[0]
        var meta: [String: JSONValue] = [
            "aggregate": .string(isMean ? "hourly_mean" : "hourly_sum"),
            "n": .number(Double(values.count)),
        ]
        if isMean, let lo = values.min(), let hi = values.max() {
            meta["min"] = .number(HealthEventMapper.round3(lo))
            meta["max"] = .number(HealthEventMapper.round3(hi))
        }
        if let b = first.source.bundleId { meta["source_bundle"] = .string(b) }
        let sameDevice = group.allSatisfy { $0.device == first.device }
        return EventRecord(
            id: HealthEventMapper.stableID("hour:\(key.type.rawValue):\(key.source):\(key.hour)"),
            at: start, loggedAt: loggedAt, source: .healthkit,
            origin: Origin(app: first.source.name, device: sameDevice ? first.device?.originLabel : nil),
            payload: .healthkit(HealthKitSampleFields(
                hkType: key.type.rawValue, value: .number(HealthEventMapper.round3(result)), unit: key.type.unit?.label,
                end: start.addingTimeInterval(3600), metadata: meta)))
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
