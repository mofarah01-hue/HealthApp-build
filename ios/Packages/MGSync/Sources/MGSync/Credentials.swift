import Foundation
#if canImport(Security)
import Security
#endif

/// What pairing leaves on the phone (ARCHITECTURE.md 5.2 step 3): the PC's base URL, this device's id, and the device
/// key the PC handed out once. The PC keeps only `sha256(device_key)`.
public struct PCCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var baseURL: URL
    public var deviceId: String
    /// base64 text exactly as the PC sent it; used verbatim as `Authorization: Bearer <deviceKey>`.
    public var deviceKey: String
    public var pcName: String
    public var pairedAt: Date
    /// The PC's Tailscale 100.x address, learned from its /v1/health answer (`tailscale_ip`). Used only when the base URL's
    /// NAME does not resolve (see `AddressFallbackTransport`). nil on a pairing saved before 2026-11-05.
    public var tailscaleIP: String?

    public init(baseURL: URL, deviceId: String, deviceKey: String, pcName: String, pairedAt: Date, tailscaleIP: String? = nil) {
        self.baseURL = baseURL
        self.deviceId = deviceId
        self.deviceKey = deviceKey
        self.pcName = pcName
        self.pairedAt = pairedAt
        self.tailscaleIP = tailscaleIP
    }

    /// Never prints the key (logs, assertion messages and string interpolation all go through this).
    public var description: String {
        "PCCredentials(pc: \(pcName), base: \(baseURL.absoluteString), device: \(deviceId), key: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Where the device key lives. The real one is the Keychain; tests use `InMemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    func load() throws -> PCCredentials?
    func save(_ credentials: PCCredentials) throws
    func clear() throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PCCredentials?

    public init(_ initial: PCCredentials? = nil) { value = initial }

    public func load() throws -> PCCredentials? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ credentials: PCCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        value = credentials
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}

#if canImport(Security)

/// The four Keychain calls the store needs, behind a seam so the attributes it writes can be checked without a real
/// Keychain (a headless `swift test` on a Mac cannot rely on one).
public protocol KeychainItemAccess: Sendable {
    func copy(query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(query: [String: Any]) -> OSStatus
}

/// SecItem* calls.
public struct SystemKeychain: KeychainItemAccess {
    public init() {}

    public func copy(query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// The device key in the iOS Keychain (ARCHITECTURE.md 5.2: service `mgapp.pclab`).
/// - Generic password item, one per install: service `mgapp.pclab`, account `device`.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by a background sync while the phone is locked
///   (after the first unlock since boot), never copied to a backup or another device.
/// - `kSecAttrSynchronizable = false`: not in iCloud Keychain.
/// The item holds the whole `PCCredentials` as JSON (base URL, device id, key, PC name).
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "mgapp.pclab"
    public static let defaultAccount = "device"

    private let service: String
    private let account: String
    private let keychain: any KeychainItemAccess

    public init(service: String = KeychainCredentialStore.defaultService,
                account: String = KeychainCredentialStore.defaultAccount,
                keychain: any KeychainItemAccess = SystemKeychain()) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(iOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public func load() throws -> PCCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copy(query: q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw SyncError.credentialStore("Keychain read failed (OSStatus \(status))")
        }
        do {
            return try JSONDecoder().decode(PCCredentials.self, from: data)
        } catch {
            throw SyncError.credentialStore("The stored pairing is unreadable (\(error))")
        }
    }

    public func save(_ credentials: PCCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = keychain.update(query: baseQuery, attributes: attributes)
        if status == errSecItemNotFound {
            status = keychain.add(baseQuery.merging(attributes) { _, new in new })
        }
        guard status == errSecSuccess else {
            throw SyncError.credentialStore("Keychain write failed (OSStatus \(status))")
        }
    }

    public func clear() throws {
        let status = keychain.delete(query: baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncError.credentialStore("Keychain delete failed (OSStatus \(status))")
        }
    }
}

#endif
