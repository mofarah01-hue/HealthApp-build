import Foundation
import MGDomain

// Settings › Profile › "Use values from Apple Health (via your PC)" (tracker #90, 2026-10-11). GET /v1/profile, written
// against app/pclab/mglab/sync_api.py `get_profile` as read on 2026-10-11: the merged profile the PC models read
// (profile.json, its empty fields filled from the profile derived from Mo's Apple Health export) with a source per
// field. Read only on both sides; the phone decides what to fill (MGContext ProfileFill) after Mo taps.

/// GET /v1/profile → 200 (sync-api.schema.json `profileGetResponse`).
public struct PCProfile: Decodable, Equatable, Sendable {
    public struct Values: Decodable, Equatable, Sendable {
        public var birthDate: String?
        public var sex: String?
        public var heightCm: Double?
        public var weightKg: Double?
        public var hrMaxMeasured: Double?
        public var hrRestBaseline: Double?
        /// D-LOAD-WALK-2: fat-free mass (kg) from the PC's InBody scan, adjusted to the current weight (not a contract profile
        /// field the phone can write; read only).
        public var fatFreeMassKg: Double?

        enum CodingKeys: String, CodingKey {
            case birthDate = "birth_date"
            case sex
            case heightCm = "height_cm"
            case weightKg = "weight_kg"
            case hrMaxMeasured = "hr_max_measured"
            case hrRestBaseline = "hr_rest_baseline"
            case fatFreeMassKg = "fat_free_mass_kg"
        }
    }

    public var profile: Values
    /// Contract field name → where the PC got it ("your phone (profile.json)", "Apple Health export (derived …)").
    public var sources: [String: String]
    /// profile.json on the PC cannot be read; `profile` then holds the derived fields only.
    public var problem: String?
}

public enum PCProfileResult: Equatable, Sendable {
    case profile(PCProfile)
    case notPaired
    /// No HTTP answer: Tailscale off, PC asleep or PC Lab not running.
    case unreachable(String)
    /// An HTTP answer that is not a profile, with the PC's reason.
    case refused(String)
}

public enum PCLabProfile {
    /// One GET /v1/profile with the paired device key (15 s). Never throws: every way it can fail is a case.
    public static func fetch(credentials: any CredentialStore,
                             transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PCProfileResult {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .refused("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await client.profile()
            return decode(status: reply.status, body: reply.body)
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch {
            return .unreachable("\(error)")
        }
    }

    static func decode(status: Int, body: Data) -> PCProfileResult {
        guard status == 200 else {
            let reason = APIReply(status: status, body: body).apiError?.reason
            if status == 404 {
                return .refused("This PC Lab has no profile route yet — restart PC Lab so it runs the new code.")
            }
            return .refused(reason ?? "HTTP \(status)")
        }
        do {
            return .profile(try JSONDecoder().decode(PCProfile.self, from: body))
        } catch {
            return .refused("The PC's profile answer couldn't be read: \(error)")
        }
    }
}
