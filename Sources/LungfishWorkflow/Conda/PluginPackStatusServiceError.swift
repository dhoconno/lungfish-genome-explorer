@preconcurrency import Foundation
import LungfishCore
import os.log

public enum PluginPackStatusServiceError: Swift.Error, LocalizedError, Equatable {
    case storageUnavailable(URL)
    case smokeTestFailed(requirement: String, reason: String)
    case verificationFailed(requirementID: String, reason: String)
    case invalidRequirementSelection(packID: String, requirementIDs: [String])
    case selectedRequirementInstallUnsupported

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let root):
            return "Storage location unavailable: \(root.path)"
        case .smokeTestFailed(let requirement, let reason):
            return "\(requirement) failed its verification check: \(reason)"
        case .verificationFailed(_, let reason):
            return reason
        case .invalidRequirementSelection(let packID, let requirementIDs):
            return requirementIDs.isEmpty
                ? "Select at least one tool requirement from \(packID)."
                : "Unknown tool requirements in \(packID): \(requirementIDs.joined(separator: ", "))."
        case .selectedRequirementInstallUnsupported:
            return "This plugin provider does not support installing selected tool requirements."
        }
    }
}
