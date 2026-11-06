import Foundation

/// "Is this Health sample one this app wrote?" — the rule behind the no-re-import-loop requirement (PLAN §3.1: "when
/// reading, skip samples whose source is our own app"; ARCHITECTURE.md 4.10).
///
/// Two layers use it:
/// 1. At query time the HealthKit layer excludes this build's own source with a HealthKit predicate,
///    `NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))`
///    (noop:StrandiOS/Health/HealthKitBridge.swift L1431; see `HealthKitLayer.swift`).
/// 2. `HealthReader` applies this rule to whatever comes back, because the predicate only knows the CURRENT build's
///    source. A sideloaded app is re-signed with another bundle id every few weeks, so samples the mirror wrote under a
///    previous signing carry a different source and would be read back as someone else's. The mirror therefore also
///    stamps every sample it writes with an external id starting `mgapp:` and the device "WHOOP MG" (WHOOP), and the
///    rule recognises both.
public struct OwnSourceRule: Sendable, Equatable {
    /// Prefix of `HKMetadataKeyExternalUUID` on every sample the mirror writes (`mgapp:<metric>:<day or ts>`).
    public static let externalUUIDPrefix = "mgapp:"

    /// This build's bundle id (`Bundle.main.bundleIdentifier`).
    public var bundleId: String
    /// The un-suffixed bundle id (`$(BUNDLE_ID_PREFIX).mgapp`, ARCHITECTURE.md D1). Sideload tools append a team or
    /// random suffix to it, so every `<family>` or `<family>.<anything>` is ours. Nil = match `bundleId` only.
    public var familyBundleId: String?
    /// The device the mirror labels its samples with.
    public var mirrorDeviceName: String
    public var mirrorDeviceManufacturer: String

    public init(bundleId: String, familyBundleId: String? = nil, mirrorDeviceName: String = MirrorDevice.defaultName,
                mirrorDeviceManufacturer: String = MirrorDevice.defaultManufacturer) {
        self.bundleId = bundleId
        self.familyBundleId = familyBundleId
        self.mirrorDeviceName = mirrorDeviceName
        self.mirrorDeviceManufacturer = mirrorDeviceManufacturer
    }

    public func isOwn(_ record: HealthSampleRecord) -> Bool {
        isOwn(sourceBundleId: record.source.bundleId, externalUUID: record.metadata[HealthMetadataKey.externalUUID],
              device: record.device)
    }

    public func isOwn(sourceBundleId: String?, externalUUID: String?, device: HealthDeviceInfo?) -> Bool {
        if let id = sourceBundleId {
            if id == bundleId { return true }
            if let family = familyBundleId, id == family || id.hasPrefix(family + ".") { return true }
        }
        if let ext = externalUUID, ext.hasPrefix(OwnSourceRule.externalUUIDPrefix) { return true }
        if let d = device, d.name == mirrorDeviceName, d.manufacturer == mirrorDeviceManufacturer { return true }
        return false
    }
}
