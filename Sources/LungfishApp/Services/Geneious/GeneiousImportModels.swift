import Foundation

public enum GeneiousImportSourceKind: String, Codable, Sendable {
    case geneiousArchive
    case folder
    case file
}

public enum GeneiousImportItemKind: String, Codable, Sendable {
    case geneiousXML
    case geneiousSidecar
    case standaloneReferenceSequence
    case annotationTrack
    case variantTrack
    case alignmentTrack
    case fastq
    case signalTrack
    case treeOrAlignment
    case report
    case binaryArtifact
    case unsupported
}

public struct GeneiousImportItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sourceRelativePath: String
    public let stagedRelativePath: String?
    public let kind: GeneiousImportItemKind
    public let lgeDestination: String?
    public let sizeBytes: UInt64?
    public let sha256: String?
    public let geneiousDocumentClass: String?
    public let geneiousDocumentName: String?
    public let warnings: [String]

    public init(
        id: UUID = UUID(),
        sourceRelativePath: String,
        stagedRelativePath: String? = nil,
        kind: GeneiousImportItemKind,
        lgeDestination: String? = nil,
        sizeBytes: UInt64? = nil,
        sha256: String? = nil,
        geneiousDocumentClass: String? = nil,
        geneiousDocumentName: String? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.sourceRelativePath = sourceRelativePath
        self.stagedRelativePath = stagedRelativePath
        self.kind = kind
        self.lgeDestination = lgeDestination
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.geneiousDocumentClass = geneiousDocumentClass
        self.geneiousDocumentName = geneiousDocumentName
        self.warnings = warnings
    }
}

public struct GeneiousImportInventory: Codable, Sendable, Equatable {
    public let sourceURL: URL
    public let sourceKind: GeneiousImportSourceKind
    public let sourceName: String
    public let createdAt: Date
    public let geneiousVersion: String?
    public let geneiousMinimumVersion: String?
    public let items: [GeneiousImportItem]
    public let documentClasses: [String]
    public let unresolvedURNs: [String]
    public let warnings: [String]

    public init(
        sourceURL: URL,
        sourceKind: GeneiousImportSourceKind,
        sourceName: String,
        createdAt: Date = Date(),
        geneiousVersion: String? = nil,
        geneiousMinimumVersion: String? = nil,
        items: [GeneiousImportItem],
        documentClasses: [String] = [],
        unresolvedURNs: [String] = [],
        warnings: [String] = []
    ) {
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.geneiousVersion = geneiousVersion
        self.geneiousMinimumVersion = geneiousMinimumVersion
        self.items = items
        self.documentClasses = documentClasses
        self.unresolvedURNs = unresolvedURNs
        self.warnings = warnings
    }
}

public struct GeneiousImportOptions: Sendable, Equatable {
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

    public static let `default` = GeneiousImportOptions()
}

public struct GeneiousImportResult: Sendable, Equatable {
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
