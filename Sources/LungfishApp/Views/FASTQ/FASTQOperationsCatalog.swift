import Foundation
import LungfishWorkflow

/// The operation categories of the FASTQ operations dialog, the dataset
/// launchers, the Workflow Library and the Tools menu.
///
/// The case order is the Tools menu order. The raw values are strings, so
/// reordering the cases changes nothing that is stored.
enum FASTQOperationCategoryID: String, CaseIterable, Sendable {
    case qcReporting
    case demultiplexing
    case trimmingFiltering
    case decontamination
    case readProcessing
    case searchSubsetting
    case mapping
    case variantCalling
    case assembly
    case clustering
    case classification
    case genotyping
    case alignment

    /// The one name for this category wherever a user sees it. The Tools menu,
    /// the dataset launchers and the Workflow Library read it directly and the
    /// dialog's uppercase `title` derives from it.
    var displayName: String {
        switch self {
        case .qcReporting: return "QC & Reporting"
        case .demultiplexing: return "Demultiplexing"
        case .trimmingFiltering: return "Trimming & Filtering"
        case .decontamination: return "Decontamination"
        case .readProcessing: return "Read Processing"
        case .searchSubsetting: return "Search & Subsetting"
        case .mapping: return "Mapping"
        case .variantCalling: return "Variant Calling"
        case .assembly: return "Assembly"
        case .clustering: return "Clustering"
        case .classification: return "Classification"
        case .genotyping: return "Genotyping"
        case .alignment: return "Alignment & Phylogenetics"
        }
    }

    /// The uppercase header the FASTQ operations dialog shows.
    var title: String {
        displayName.uppercased()
    }

    var requiredPackIDs: [String] {
        switch self {
        case .qcReporting, .demultiplexing, .trimmingFiltering, .decontamination, .readProcessing, .searchSubsetting, .clustering, .genotyping:
            return []
        case .alignment:
            return ["multiple-sequence-alignment"]
        case .mapping:
            return ["read-mapping"]
        case .variantCalling:
            // Viral Recon moved here from mapping, so the packs that gate it stay the same.
            return FASTQOperationCategoryID.mapping.requiredPackIDs
        case .assembly:
            return ["assembly"]
        case .classification:
            return ["metagenomics"]
        }
    }

    /// The tool the dialog selects first when it opens on this category.
    var defaultToolID: FASTQOperationToolID {
        switch self {
        case .qcReporting:
            return .refreshQCSummary
        case .demultiplexing:
            return .demultiplexBarcodes
        case .trimmingFiltering:
            return .fastpTrim
        case .decontamination:
            return .removeHumanReads
        case .readProcessing:
            return .mergeOverlappingPairs
        case .searchSubsetting:
            return .subsampleByProportion
        case .mapping:
            return .minimap2
        case .variantCalling:
            return .viralRecon
        case .assembly:
            return .spades
        case .clustering:
            return .pbaa
        case .classification:
            return .kraken2
        case .genotyping:
            return .ontGenotyping
        case .alignment:
            return .mafft
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
