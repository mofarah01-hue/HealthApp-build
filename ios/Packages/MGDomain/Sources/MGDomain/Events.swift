import CryptoKit
import Foundation

/// Contract `eventBase.type`.
public enum EventType: String, Codable, Sendable, CaseIterable {
    case journal = "journal"
    case substance = "substance"
    case medication = "medication"
    case workout = "workout"
    case ecg = "ecg"
    case spo2Session = "spo2_session"
    case bpCuff = "bp_cuff"
    case marker = "marker"
    case food = "food"
    case symptom = "symptom"
    case checkin = "checkin"
    case reactionTest = "reaction_test"
    case nap = "nap"
    case audio = "audio"
    case strapWrite = "strap_write"
    case healthkit = "healthkit"
    case wear = "wear"
    case scan = "scan"
    case record = "record"
    case screenTime = "screen_time"
    case focusState = "focus_state"
    case breathingEvent = "breathing_event"
    case activityLabel = "activity_label"
}

/// Contract `eventBase.source`.
public enum EventSource: String, Codable, Sendable, CaseIterable {
    case manual = "manual"
    case shortcut = "shortcut"
    case widget = "widget"
    case healthkit = "healthkit"
    case strap = "strap"
    case detected = "detected"
    case vault = "vault"
    case `import` = "import"
    case aiEstimate = "ai_estimate"
    case pc = "pc"
}

/// Contract `$defs/wearLocation` (PLAN.md 4.12).
public enum WearLocation: String, Codable, Sendable, CaseIterable {
    case leftWrist = "left_wrist"
    case rightWrist = "right_wrist"
    case leftBicep = "left_bicep"
    case rightBicep = "right_bicep"
    case bodyTorso = "body_torso"
    case bodyWaist = "body_waist"
    case unknown = "unknown"
    case tailboneUnderwear = "tailbone_underwear"
    case other = "other"
}

/// Contract `eventBase.attachments[]`.
public struct Attachment: Codable, Hashable, Sendable {
    /// `days/<date>/attachments/...`
    public var path: String
    public var mime: String?
    public var sha256: String?

    public init(path: String, mime: String? = nil, sha256: String? = nil) {
        self.path = path
        self.mime = mime
        self.sha256 = sha256
    }
}

/// Contract `eventBase.location`: coarse, or a saved place by default.
public struct EventLocation: Codable, Hashable, Sendable {
    public var label: String?
    public var savedPlaceId: String?
    public var lat: Double?
    public var lon: Double?

    public init(label: String? = nil, savedPlaceId: String? = nil, lat: Double? = nil, lon: Double? = nil) {
        self.label = label
        self.savedPlaceId = savedPlaceId
        self.lat = lat
        self.lon = lon
    }

    enum CodingKeys: String, CodingKey {
        case label = "label"
        case savedPlaceId = "saved_place_id"
        case lat = "lat"
        case lon = "lon"
    }
}

/// Contract `eventBase` + one typed payload, encoded as ONE flat JSON object (the schema's `allOf`).
///
/// v0.5 proposals (ARCHITECTURE.md D10): `id`, `revision` (+1 on every edit), `removed` (soft remove) are always
/// written. A v0.4 event read without them gets revision 1, removed false, and an id derived from its content
/// (SHA-256 of the event as canonical UTC JSON), so reading the same file twice gives the same id. `id` is written in
/// lowercase, as Python's `uuid` writes it, so the PC's merge-by-id sees one event, not two.
public struct EventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var revision: Int
    public var removed: Bool
    public var type: EventType
    public var at: Date
    public var loggedAt: Date?
    public var source: EventSource
    public var origin: Origin?
    public var wearLocation: WearLocation?
    public var note: String?
    public var follows: Date?
    public var attachments: [Attachment]?
    public var location: EventLocation?
    /// Decoded by `type` via the contract event-type-map. Must match `type` (see `validate()`); encoding throws if not.
    public var payload: EventPayload

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        removed: Bool = false,
        type: EventType,
        at: Date,
        loggedAt: Date? = nil,
        source: EventSource,
        origin: Origin? = nil,
        wearLocation: WearLocation? = nil,
        note: String? = nil,
        follows: Date? = nil,
        attachments: [Attachment]? = nil,
        location: EventLocation? = nil,
        payload: EventPayload
    ) {
        self.id = id
        self.revision = revision
        self.removed = removed
        self.type = type
        self.at = at
        self.loggedAt = loggedAt
        self.source = source
        self.origin = origin
        self.wearLocation = wearLocation
        self.note = note
        self.follows = follows
        self.attachments = attachments
        self.location = location
        self.payload = payload
    }

    /// Same, with `type` taken from the payload (`.none` -> `focus_state`).
    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        removed: Bool = false,
        at: Date,
        loggedAt: Date? = nil,
        source: EventSource,
        origin: Origin? = nil,
        wearLocation: WearLocation? = nil,
        note: String? = nil,
        follows: Date? = nil,
        attachments: [Attachment]? = nil,
        location: EventLocation? = nil,
        payload: EventPayload
    ) {
        self.init(id: id, revision: revision, removed: removed, type: payload.eventType ?? .focusState, at: at,
                  loggedAt: loggedAt, source: source, origin: origin, wearLocation: wearLocation, note: note,
                  follows: follows, attachments: attachments, location: location, payload: payload)
    }

    /// Rule violations; empty = valid.
    public func validate() -> [String] {
        var v: [String] = []
        if !payload.matches(type) {
            v.append("event \(id): type \(type.rawValue) carries a \(payload.eventType?.rawValue ?? "focus_state") payload")
        }
        if revision < 1 { v.append("event \(id): revision \(revision) < 1") }
        return v
    }

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case revision = "revision"
        case removed = "removed"
        case type = "type"
        case at = "at"
        case loggedAt = "logged_at"
        case source = "source"
        case origin = "origin"
        case wearLocation = "wear_location"
        case note = "note"
        case follows = "follows"
        case attachments = "attachments"
        case location = "location"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(EventType.self, forKey: .type)
        at = try c.decode(Date.self, forKey: .at)
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt)
        source = try c.decode(EventSource.self, forKey: .source)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        wearLocation = try c.decodeIfPresent(WearLocation.self, forKey: .wearLocation)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        follows = try c.decodeIfPresent(Date.self, forKey: .follows)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
        location = try c.decodeIfPresent(EventLocation.self, forKey: .location)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        payload = try EventPayload.decode(type: type, from: decoder)
        if let raw = try c.decodeIfPresent(String.self, forKey: .id) {
            guard let uuid = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "event id is not a UUID: \(raw)")
            }
            id = uuid
        } else {
            id = EventRecord.placeholderID
            id = try EventRecord.contentID(of: self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard payload.matches(type) else {
            throw EncodingError.invalidValue(payload, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "event type \(type.rawValue) carries a \(payload.eventType?.rawValue ?? "focus_state") payload"))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(revision, forKey: .revision)
        try c.encode(removed, forKey: .removed)
        try c.encode(type, forKey: .type)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(loggedAt, forKey: .loggedAt)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(wearLocation, forKey: .wearLocation)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(follows, forKey: .follows)
        try c.encodeIfPresent(attachments, forKey: .attachments)
        try c.encodeIfPresent(location, forKey: .location)
        try payload.encodeFields(to: encoder)
    }

    static let placeholderID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Content-derived id for a v0.4 event that arrived without one: SHA-256 of the event encoded as canonical JSON
    /// (sorted keys, UTC dates, the all-zero placeholder id), first 16 bytes, RFC 9562 version 8 + variant bits.
    static func contentID(of event: EventRecord) throws -> UUID {
        var e = event
        e.id = placeholderID
        let bytes = try MGJSON.encoder(timeZone: TimeZone(secondsFromGMT: 0)!).encode(e)
        var h = Array(SHA256.hash(data: bytes).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x80   // version 8 (custom)
        h[8] = (h[8] & 0x3F) | 0x80   // RFC 4122 / 9562 variant
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                           h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }
}
