import Foundation

public enum ApplicationExportKind: String, Codable, Sendable, CaseIterable, Equatable {
    case clcWorkbench = "clc-workbench-export"
    case dnastarLasergene = "dnastar-lasergene-export"
    case benchlingBulk = "benchling-bulk-export"
    case sequenceDesignLibrary = "sequence-design-library-export"
    case alignmentTree = "alignment-tree-export"
    case sequencingPlatformRunFolder = "sequencing-platform-run-folder"
    case phylogeneticsResultSet = "phylogenetics-result-set"
    case qiime2Archive = "qiime2-archive"
    case igvSessionTrackSet = "igv-session-track-set"

    public var cardID: String { rawValue }

    public var displayName: String {
        switch self {
        case .clcWorkbench: return "CLC Workbench"
        case .dnastarLasergene: return "DNASTAR Lasergene"
        case .benchlingBulk: return "Benchling Bulk"
        case .sequenceDesignLibrary: return "Sequence Library"
        case .alignmentTree: return "Alignment Tree"
        case .sequencingPlatformRunFolder: return "Sequencing Run"
        case .phylogeneticsResultSet: return "Phylogenetics"
        case .qiime2Archive: return "QIIME 2"
        case .igvSessionTrackSet: return "IGV Session"
        }
    }

    public var collectionSuffix: String { displayName }

    public var importsNativeBundlesOnly: Bool {
        switch self {
        case .alignmentTree, .phylogeneticsResultSet:
            return true
        default:
            return false
        }
    }

    public var cliArgument: String {
        switch self {
        case .clcWorkbench: return "clc-workbench"
        case .dnastarLasergene: return "dnastar-lasergene"
        case .benchlingBulk: return "benchling-bulk"
        case .sequenceDesignLibrary: return "sequence-design-library"
        case .alignmentTree: return "alignment-tree"
        case .sequencingPlatformRunFolder: return "sequencing-platform-run-folder"
        case .phylogeneticsResultSet: return "phylogenetics-result-set"
        case .qiime2Archive: return "qiime2-archive"
        case .igvSessionTrackSet: return "igv-session-track-set"
        }
    }
}

public enum ApplicationExportImportSourceKind: String, Codable, Sendable {
    case archive
    case folder
    case file
}

public enum ApplicationExportImportItemKind: String, Codable, Sendable {
    case standaloneReferenceSequence
    case annotationTrack
    case variantTrack
    case alignmentTrack
    case fastq
    case signalTrack
    case multipleSequenceAlignment
    case phylogeneticTree
    case treeOrAlignment
    case phylogeneticsArtifact
    case platformMetadata
    case report
    case nativeProject
    case binaryArtifact
    case unsupported
}

public struct ApplicationExportImportItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sourceRelativePath: String
    public let stagedRelativePath: String?
    public let kind: ApplicationExportImportItemKind
    public let lgeDestination: String?
    public let sizeBytes: UInt64?
    public let sha256: String?
    public let warnings: [String]

    public init(
        id: UUID = UUID(),
        sourceRelativePath: String,
        stagedRelativePath: String? = nil,
        kind: ApplicationExportImportItemKind,
        lgeDestination: String? = nil,
        sizeBytes: UInt64? = nil,
        sha256: String? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.sourceRelativePath = sourceRelativePath
        self.stagedRelativePath = stagedRelativePath
        self.kind = kind
        self.lgeDestination = lgeDestination
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.warnings = warnings
    }
}

public struct ApplicationExportImportInventory: Codable, Sendable, Equatable {
    public let sourceURL: URL
    public let sourceKind: ApplicationExportImportSourceKind
    public let sourceName: String
    public let applicationKind: ApplicationExportKind
    public let createdAt: Date
    public let items: [ApplicationExportImportItem]
    public let warnings: [String]

    public init(
        sourceURL: URL,
        sourceKind: ApplicationExportImportSourceKind,
        sourceName: String,
        applicationKind: ApplicationExportKind,
        createdAt: Date = Date(),
        items: [ApplicationExportImportItem],
        warnings: [String] = []
    ) {
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.applicationKind = applicationKind
        self.createdAt = createdAt
        self.items = items
        self.warnings = warnings
    }
}

public struct ApplicationExportImportOptions: Sendable, Equatable {
    public var collectionName: String?
    public var preserveRawSource: Bool
    public var importStandaloneReferences: Bool
    public var preserveUnsupportedArtifacts: Bool

    public init(
        collectionName: String? = nil,
        preserveRawSource: Bool = true,
        importStandaloneReferences: Bool = true,
        preserveUnsupportedArtifacts: Bool = true
    ) {
        self.collectionName = collectionName
        self.preserveRawSource = preserveRawSource
        self.importStandaloneReferences = importStandaloneReferences
        self.preserveUnsupportedArtifacts = preserveUnsupportedArtifacts
    }

    public static let `default` = ApplicationExportImportOptions()
}

public struct ApplicationExportImportResult: Sendable, Equatable {
    public let collectionURL: URL
    public let inventoryURL: URL
    public let reportURL: URL
    public let provenanceURL: URL
    public let nativeBundleURLs: [URL]
    public let preservedArtifactURLs: [URL]
    public let warnings: [String]

    public init(
        collectionURL: URL,
        inventoryURL: URL,
        reportURL: URL,
        provenanceURL: URL,
        nativeBundleURLs: [URL],
        preservedArtifactURLs: [URL],
        warnings: [String]
    ) {
        self.collectionURL = collectionURL
        self.inventoryURL = inventoryURL
        self.reportURL = reportURL
        self.provenanceURL = provenanceURL
        self.nativeBundleURLs = nativeBundleURLs
        self.preservedArtifactURLs = preservedArtifactURLs
        self.warnings = warnings
    }

    public var warningCount: Int { warnings.count }
}
