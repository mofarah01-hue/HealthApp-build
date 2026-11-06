import Foundation
import MGDomain

/// The strap's stable id in our data. The derivation lives in one place, MGDomain's `StrapID.derive` ("s_" + first
/// 16 hex of SHA256(installSalt ‖ peripheral UUID string)); this only names the inputs MGBLE has. The peripheral
/// UUID is iOS's per-phone identifier, never the strap serial (project CLAUDE.md rule 6).
enum StrapIdentity {
    static func strapID(installSalt: Data, peripheralID: UUID) -> StrapID {
        StrapID.derive(installSalt: installSalt, peripheralID: peripheralID)
    }
}
