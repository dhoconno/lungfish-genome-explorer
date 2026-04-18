import Foundation
import Observation

@MainActor
@Observable
final class FASTQOperationDialogState {
    var selectedCategory: FASTQOperationCategoryID {
        didSet {
            if selectedToolID.categoryID != selectedCategory {
                selectedToolID = selectedCategory.defaultToolID
                return
            }

            normalizeOutputMode()
        }
    }

    var selectedToolID: FASTQOperationToolID {
        didSet {
            if selectedCategory != selectedToolID.categoryID {
                selectedCategory = selectedToolID.categoryID
                return
            }

            normalizeOutputMode()
        }
    }

    var selectedInputURLs: [URL]
    var outputMode: FASTQOperationOutputMode {
        didSet {
            normalizeOutputMode()
        }
    }

    init(initialCategory: FASTQOperationCategoryID, selectedInputURLs: [URL]) {
        let defaultToolID = initialCategory.defaultToolID
        self.selectedCategory = initialCategory
        self.selectedToolID = defaultToolID
        self.selectedInputURLs = selectedInputURLs
        self.outputMode = defaultToolID.defaultOutputMode
    }

    func selectCategory(_ category: FASTQOperationCategoryID) {
        selectedCategory = category
        selectedToolID = category.defaultToolID
        outputMode = selectedToolID.defaultOutputMode
    }

    func selectTool(_ toolID: FASTQOperationToolID) {
        selectedCategory = toolID.categoryID
        selectedToolID = toolID
        outputMode = toolID.defaultOutputMode
    }

    var showsOutputStrategyPicker: Bool {
        selectedToolID.categoryID != .classification
    }

    var requiredInputKinds: [FASTQOperationInputKind] {
        selectedToolID.requiredInputKinds
    }

    var isRunEnabled: Bool {
        !selectedInputURLs.isEmpty && requiredInputKinds.allSatisfy { $0 == .fastqDataset }
    }

    var datasetLabel: String {
        switch selectedInputURLs.count {
        case 0:
            return "No FASTQ selected"
        case 1:
            return selectedInputURLs[0].lastPathComponent
        default:
            return "\(selectedInputURLs.count) FASTQ datasets"
        }
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        Self.toolIDs(for: selectedCategory).map(\.sidebarItem)
    }

    static func toolIDs(for category: FASTQOperationCategoryID) -> [FASTQOperationToolID] {
        switch category {
        case .qcReporting:
            return [.refreshQCSummary]
        case .demultiplexing:
            return [.demultiplexBarcodes]
        case .trimmingFiltering:
            return [.qualityTrim, .adapterRemoval, .primerTrimming, .trimFixedBases, .filterByReadLength]
        case .decontamination:
            return [.removeHumanReads, .removeContaminants, .removeDuplicates]
        case .readProcessing:
            return [.mergeOverlappingPairs, .repairPairedEndFiles, .orientReads, .correctSequencingErrors]
        case .searchSubsetting:
            return [.subsampleByProportion, .subsampleByCount, .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence]
        case .mapping:
            return [.minimap2]
        case .assembly:
            return [.spades]
        case .classification:
            return [.kraken2, .esViritu, .taxTriage]
        }
    }
}

enum FASTQOperationToolID: String, CaseIterable, Sendable {
    case refreshQCSummary
    case demultiplexBarcodes
    case qualityTrim
    case adapterRemoval
    case primerTrimming
    case trimFixedBases
    case filterByReadLength
    case removeHumanReads
    case removeContaminants
    case removeDuplicates
    case mergeOverlappingPairs
    case repairPairedEndFiles
    case orientReads
    case correctSequencingErrors
    case subsampleByProportion
    case subsampleByCount
    case extractReadsByID
    case extractReadsByMotif
    case selectReadsBySequence
    case minimap2
    case spades
    case kraken2
    case esViritu
    case taxTriage

    var title: String {
        switch self {
        case .refreshQCSummary: return "Refresh QC Summary"
        case .demultiplexBarcodes: return "Demultiplex Barcodes"
        case .qualityTrim: return "Quality Trim"
        case .adapterRemoval: return "Adapter Removal"
        case .primerTrimming: return "Primer Trimming"
        case .trimFixedBases: return "Trim Fixed Bases"
        case .filterByReadLength: return "Filter by Read Length"
        case .removeHumanReads: return "Remove Human Reads"
        case .removeContaminants: return "Remove Contaminants"
        case .removeDuplicates: return "Remove Duplicates"
        case .mergeOverlappingPairs: return "Merge Overlapping Pairs"
        case .repairPairedEndFiles: return "Repair Paired-End Files"
        case .orientReads: return "Orient Reads"
        case .correctSequencingErrors: return "Correct Sequencing Errors"
        case .subsampleByProportion: return "Subsample by Proportion"
        case .subsampleByCount: return "Subsample by Count"
        case .extractReadsByID: return "Extract Reads by ID"
        case .extractReadsByMotif: return "Extract Reads by Motif"
        case .selectReadsBySequence: return "Select Reads by Sequence"
        case .minimap2: return "minimap2"
        case .spades: return "SPAdes"
        case .kraken2: return "Kraken2"
        case .esViritu: return "EsViritu"
        case .taxTriage: return "TaxTriage"
        }
    }

    var subtitle: String {
        switch self {
        case .refreshQCSummary: return "Rebuild the QC summary for the current FASTQ data."
        case .demultiplexBarcodes: return "Split pooled reads into barcode-defined samples."
        case .qualityTrim: return "Trim low-quality bases from read ends."
        case .adapterRemoval: return "Remove adapter sequence from reads."
        case .primerTrimming: return "Trim PCR primer sequence from reads."
        case .trimFixedBases: return "Remove a fixed number of bases from either end."
        case .filterByReadLength: return "Keep reads in a requested length range."
        case .removeHumanReads: return "Remove reads against a human database."
        case .removeContaminants: return "Remove spike-ins or other contaminant sequences."
        case .removeDuplicates: return "Collapse duplicate reads."
        case .mergeOverlappingPairs: return "Merge overlapping paired-end reads."
        case .repairPairedEndFiles: return "Restore proper pairing for FASTQ mates."
        case .orientReads: return "Orient reads to a reference strand."
        case .correctSequencingErrors: return "Correct random sequencing errors."
        case .subsampleByProportion: return "Keep a fraction of the input reads."
        case .subsampleByCount: return "Keep a fixed number of reads."
        case .extractReadsByID: return "Select reads matching identifiers."
        case .extractReadsByMotif: return "Select reads containing a motif."
        case .selectReadsBySequence: return "Select reads matching a sequence."
        case .minimap2: return "Map reads to a reference sequence."
        case .spades: return "Assemble reads into contigs."
        case .kraken2: return "Classify reads taxonomically."
        case .esViritu: return "Detect viruses and report coverage."
        case .taxTriage: return "Run the TaxTriage pathogen workflow."
        }
    }

    var categoryID: FASTQOperationCategoryID {
        switch self {
        case .refreshQCSummary:
            return .qcReporting
        case .demultiplexBarcodes:
            return .demultiplexing
        case .qualityTrim, .adapterRemoval, .primerTrimming, .trimFixedBases, .filterByReadLength:
            return .trimmingFiltering
        case .removeHumanReads, .removeContaminants, .removeDuplicates:
            return .decontamination
        case .mergeOverlappingPairs, .repairPairedEndFiles, .orientReads, .correctSequencingErrors:
            return .readProcessing
        case .subsampleByProportion, .subsampleByCount, .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence:
            return .searchSubsetting
        case .minimap2:
            return .mapping
        case .spades:
            return .assembly
        case .kraken2, .esViritu, .taxTriage:
            return .classification
        }
    }

    var requiredInputKinds: [FASTQOperationInputKind] {
        switch self {
        case .refreshQCSummary:
            return [.fastqDataset]
        case .demultiplexBarcodes:
            return [.fastqDataset, .barcodeDefinition]
        case .qualityTrim, .adapterRemoval, .trimFixedBases, .filterByReadLength,
             .removeDuplicates, .mergeOverlappingPairs, .repairPairedEndFiles,
             .correctSequencingErrors, .subsampleByProportion, .subsampleByCount,
             .extractReadsByID, .extractReadsByMotif, .selectReadsBySequence, .spades:
            return [.fastqDataset]
        case .primerTrimming:
            return [.fastqDataset, .primerSource]
        case .removeHumanReads, .kraken2, .esViritu, .taxTriage:
            return [.fastqDataset, .database]
        case .removeContaminants:
            return [.fastqDataset, .contaminantReference]
        case .orientReads, .minimap2:
            return [.fastqDataset, .referenceSequence]
        }
    }

    var defaultOutputMode: FASTQOperationOutputMode {
        categoryID == .classification ? .fixedBatch : .perInput
    }

    var sidebarItem: DatasetOperationToolSidebarItem {
        DatasetOperationToolSidebarItem(
            id: rawValue,
            title: title,
            subtitle: subtitle,
            availability: .available
        )
    }
}

enum FASTQOperationInputKind: String, CaseIterable, Sendable {
    case fastqDataset
    case referenceSequence
    case database
    case barcodeDefinition
    case primerSource
    case contaminantReference
}

enum FASTQOperationOutputMode: String, CaseIterable, Sendable {
    case perInput
    case groupedResult
    case fixedBatch
}

extension FASTQOperationCategoryID {
    var defaultToolID: FASTQOperationToolID {
        switch self {
        case .qcReporting:
            return .refreshQCSummary
        case .demultiplexing:
            return .demultiplexBarcodes
        case .trimmingFiltering:
            return .qualityTrim
        case .decontamination:
            return .removeHumanReads
        case .readProcessing:
            return .mergeOverlappingPairs
        case .searchSubsetting:
            return .subsampleByProportion
        case .mapping:
            return .minimap2
        case .assembly:
            return .spades
        case .classification:
            return .kraken2
        }
    }
}

private extension FASTQOperationDialogState {
    func normalizeOutputMode() {
        let enforcedMode = selectedToolID.defaultOutputMode
        if outputMode != enforcedMode {
            outputMode = enforcedMode
        }
    }
}
