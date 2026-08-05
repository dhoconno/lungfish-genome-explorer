import Foundation
import LungfishWorkflow

enum SavontRuntimeReadiness: Equatable, Sendable {
    case checking
    case ready
    case installRequired
    case repairRequired

    var allowsRun: Bool {
        self == .ready
    }

    var blockingMessage: String? {
        switch self {
        case .checking:
            return "Checking the managed Savont runtime…"
        case .ready:
            return nil
        case .installRequired:
            return "Install the Full-length MHC Genotyping pack in Plugin Manager to run Savont."
        case .repairRequired:
            return "Repair the Full-length MHC Genotyping pack in Plugin Manager to restore Savont."
        }
    }
}

enum SavontRuntimePreflight {
    static let packID = "full-length-mhc-genotyping"
    static let toolID = "savont"

    static func readiness(
        using statusProvider: any PluginPackStatusProviding
    ) async -> SavontRuntimeReadiness {
        guard let packStatus = await statusProvider.status(forPackID: packID) else {
            return .installRequired
        }

        guard packStatus.state == .ready else {
            return packStatus.state == .failed ? .repairRequired : .installRequired
        }

        guard let toolStatus = packStatus.toolStatuses.first(where: { $0.requirement.id == toolID }) else {
            return .repairRequired
        }

        if toolStatus.isReady {
            return .ready
        }
        if !toolStatus.environmentExists, toolStatus.storageUnavailablePath == nil {
            return .installRequired
        }
        return .repairRequired
    }
}
