import Foundation
import LungfishWorkflow

enum FASTQOperationCategoryID: String, CaseIterable, Sendable {
    case qcReporting
    case demultiplexing
    case trimmingFiltering
    case decontamination
    case readProcessing
    case searchSubsetting
    case alignment
    case mapping
    case assembly
    case classification

    var title: String {
        switch self {
        case .qcReporting: return "QC & REPORTING"
        case .demultiplexing: return "DEMULTIPLEXING"
        case .trimmingFiltering: return "TRIMMING & FILTERING"
        case .decontamination: return "DECONTAMINATION"
        case .readProcessing: return "READ PROCESSING"
        case .searchSubsetting: return "SEARCH & SUBSETTING"
        case .alignment: return "ALIGNMENT"
        case .mapping: return "MAPPING"
        case .assembly: return "ASSEMBLY"
        case .classification: return "CLASSIFICATION"
        }
    }

    var requiredPackIDs: [String] {
        switch self {
        case .qcReporting, .demultiplexing, .trimmingFiltering, .decontamination, .readProcessing, .searchSubsetting:
            return []
        case .alignment:
            return ["multiple-sequence-alignment"]
        case .mapping:
            return ["read-mapping"]
        case .assembly:
            return ["assembly"]
        case .classification:
            return ["metagenomics"]
        }
    }
}

struct FASTQOperationCategoryDescriptor: Equatable, Sendable {
    let id: FASTQOperationCategoryID
    let title: String
    let requiredPackIDs: [String]
    let isEnabled: Bool
    let disabledReason: String?
}

struct FASTQOperationsCatalog: Sendable {
    private let statusProvider: any PluginPackStatusProviding

    init(statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.statusProvider = statusProvider
    }

    func category(id: FASTQOperationCategoryID) async -> FASTQOperationCategoryDescriptor? {
        for packID in id.requiredPackIDs {
            guard let status = await statusProvider.status(forPackID: packID),
                  status.state == .ready else {
                return FASTQOperationCategoryDescriptor(
                    id: id,
                    title: id.title,
                    requiredPackIDs: id.requiredPackIDs,
                    isEnabled: false,
                    disabledReason: disabledReason(for: packID)
                )
            }
        }

        return FASTQOperationCategoryDescriptor(
            id: id,
            title: id.title,
            requiredPackIDs: id.requiredPackIDs,
            isEnabled: true,
            disabledReason: nil
        )
    }

    private func disabledReason(for packID: String) -> String {
        guard let pack = PluginPack.builtInPack(id: packID) else {
            return "No tools available"
        }

        return "Requires \(pack.name) Pack"
    }
}
