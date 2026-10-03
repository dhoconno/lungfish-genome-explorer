import CryptoKit
import Darwin
import Foundation
import LungfishIO

struct PrimalScheme3Execution: Sendable {
    let argv: [String]
    let stdout: String
    let stderr: String
    let exitStatus: Int32
    let version: String
    let runtime: ProvenanceRuntimeIdentity
    let startedAt: Date
    let endedAt: Date
    var executableSHA256: String? = nil
    var runtimeEvidence: [String: Data] = [:]
    var capabilitiesJSON: Data? = nil
    var auditValidationJSON: Data? = nil
    var auditProvenanceJSON: Data? = nil
    var auditArgv: [String]? = nil
    var auditExitStatus: Int32? = nil
}
