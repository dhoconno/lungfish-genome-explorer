import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct MultipleSequenceAlignmentBundle: Sendable {
    public static let directoryExtension = "lungfishmsa"
    public static let toolVersion = "0.1.0"
    private static let annotationJSONRelativePath = "metadata/annotations.json"
    private static let annotationSQLiteRelativePath = "metadata/annotations.sqlite"

    public let url: URL
    public let manifest: Manifest
    public let rows: [Row]

    public init(url: URL, manifest: Manifest, rows: [Row]) {
        self.url = url
        self.manifest = manifest
        self.rows = rows
    }

    public enum SourceFormat: String, Codable, Sendable, Equatable {
        case alignedFASTA = "aligned-fasta"
        case clustal
        case phylip
        case nexus
        case stockholm
        case a2mA3m = "a2m-a3m"
    }

    public struct ImportOptions: Codable, Sendable, Equatable {
        public struct AdditionalFile: Codable, Sendable, Equatable {
            public let sourceURL: URL
            public let relativePath: String

            public init(sourceURL: URL, relativePath: String) {
                self.sourceURL = sourceURL
                self.relativePath = relativePath
            }
        }

        public let name: String?
        public let sourceFormat: SourceFormat?
        public let argv: [String]?
        public let reproducibleCommand: String?
        public let gapAlphabet: [String]
        public let workflowName: String
        public let toolName: String
        public let toolVersion: String
        public let externalToolInvocations: [ToolInvocation]
        public let inputFiles: [FileRecord]
        public let additionalFiles: [AdditionalFile]
        public let analysisToolName: String?
        public let stderr: String?
        public let wallTimeSeconds: Double?
        public let extraWarnings: [String]
        public let sourceRowMetadata: [SourceRowMetadataInput]
        public let sourceAnnotations: [SourceAnnotationInput]
        public let fastqQualitySummaries: [FASTQQualitySummaryInput]
        public let extraCapabilities: [String]

        public init(
            name: String? = nil,
            sourceFormat: SourceFormat? = nil,
            argv: [String]? = nil,
            reproducibleCommand: String? = nil,
            gapAlphabet: [String] = ["-", "."],
            workflowName: String = "multiple-sequence-alignment-import",
            toolName: String = "lungfish import msa",
            toolVersion: String = MultipleSequenceAlignmentBundle.toolVersion,
            externalToolInvocations: [ToolInvocation] = [],
            inputFiles: [FileRecord] = [],
            additionalFiles: [AdditionalFile] = [],
            analysisToolName: String? = nil,
            stderr: String? = nil,
            wallTimeSeconds: Double? = nil,
            extraWarnings: [String] = [],
            sourceRowMetadata: [SourceRowMetadataInput] = [],
            sourceAnnotations: [SourceAnnotationInput] = [],
            fastqQualitySummaries: [FASTQQualitySummaryInput] = [],
            extraCapabilities: [String] = []
        ) {
            self.name = name
            self.sourceFormat = sourceFormat
            self.argv = argv
            self.reproducibleCommand = reproducibleCommand
            self.gapAlphabet = gapAlphabet
            self.workflowName = workflowName
            self.toolName = toolName
            self.toolVersion = toolVersion
            self.externalToolInvocations = externalToolInvocations
            self.inputFiles = inputFiles
            self.additionalFiles = additionalFiles
            self.analysisToolName = analysisToolName
            self.stderr = stderr
            self.wallTimeSeconds = wallTimeSeconds
            self.extraWarnings = extraWarnings
            self.sourceRowMetadata = sourceRowMetadata
            self.sourceAnnotations = sourceAnnotations
            self.fastqQualitySummaries = fastqQualitySummaries
            self.extraCapabilities = extraCapabilities
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let bundleKind: String
        public let identifier: String
        public let name: String
        public let createdAt: Date
        public let sourceFormat: SourceFormat
        public let sourceFileName: String
        public let rowCount: Int
        public let alignedLength: Int
        public let alphabet: String
        public let gapAlphabet: [String]
        public let referenceRowID: String?
        public let warnings: [String]
        public let capabilities: [String]
        public let consensus: String
        public let variableSiteCount: Int
        public let parsimonyInformativeSiteCount: Int
        public let checksums: [String: String]
        public let fileSizes: [String: Int64]

        fileprivate func copying(
            capabilities: [String]? = nil,
            checksums: [String: String]? = nil,
            fileSizes: [String: Int64]? = nil
        ) -> Manifest {
            Manifest(
                schemaVersion: schemaVersion,
                bundleKind: bundleKind,
                identifier: identifier,
                name: name,
                createdAt: createdAt,
                sourceFormat: sourceFormat,
                sourceFileName: sourceFileName,
                rowCount: rowCount,
                alignedLength: alignedLength,
                alphabet: alphabet,
                gapAlphabet: gapAlphabet,
                referenceRowID: referenceRowID,
                warnings: warnings,
                capabilities: capabilities ?? self.capabilities,
                consensus: consensus,
                variableSiteCount: variableSiteCount,
                parsimonyInformativeSiteCount: parsimonyInformativeSiteCount,
                checksums: checksums ?? self.checksums,
                fileSizes: fileSizes ?? self.fileSizes
            )
        }
    }

    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let sourceName: String
        public let displayName: String
        public let order: Int
        public let alphabet: String
        public let alignedLength: Int
        public let ungappedLength: Int
        public let gapCount: Int
        public let ambiguousCount: Int
        public let checksumSHA256: String
        public let accession: String?
        public let organism: String?
        public let geneProduct: String?
        public let haplotypeClade: String?
        public let metadata: [String: String]
    }

    public struct ColumnStat: Codable, Sendable, Equatable {
        public let index: Int
        public let consensusResidue: String
        public let residueCounts: [String: Int]
        public let gapFraction: Double
        public let conservation: Double
        public let entropy: Double
        public let variableSite: Bool
        public let parsimonyInformative: Bool
    }

    public struct SourceRowMetadataInput: Codable, Sendable, Equatable {
        public let rowName: String
        public let originalName: String
        public let sourceSequenceName: String
        public let sourceFilePath: String
        public let sourceFormat: String
        public let sourceChecksumSHA256: String

        public init(
            rowName: String,
            originalName: String,
            sourceSequenceName: String,
            sourceFilePath: String,
            sourceFormat: String,
            sourceChecksumSHA256: String
        ) {
            self.rowName = rowName
            self.originalName = originalName
            self.sourceSequenceName = sourceSequenceName
            self.sourceFilePath = sourceFilePath
            self.sourceFormat = sourceFormat
            self.sourceChecksumSHA256 = sourceChecksumSHA256
        }
    }

    public struct SourceRowMetadata: Codable, Sendable, Equatable {
        public let rowID: String
        public let rowName: String
        public let originalName: String
        public let sourceSequenceName: String
        public let sourceFilePath: String
        public let sourceFormat: String
        public let sourceChecksumSHA256: String
    }

    public struct RowCoordinateMap: Codable, Sendable, Equatable {
        public let rowID: String
        public let rowName: String
        public let alignedLength: Int
        public let ungappedLength: Int
        public let alignmentToUngapped: [Int?]
        public let ungappedToAlignment: [Int]
    }

    public enum AnnotationOrigin: String, Codable, Sendable, Equatable {
        case source
        case manual
        case projected
    }

    public enum AnnotationProjectionConflictPolicy: String, Codable, Sendable, Equatable {
        case append
        case skipOverlaps = "skip-overlaps"
        case replaceOverlaps = "replace-overlaps"
    }

    public struct SourceAnnotationInput: Codable, Sendable, Equatable {
        public let rowName: String
        public let sourceSequenceName: String
        public let sourceFilePath: String
        public let sourceTrackID: String
        public let sourceTrackName: String
        public let sourceAnnotationID: String
        public let name: String
        public let type: String
        public let strand: String
        public let intervals: [AnnotationInterval]
        public let qualifiers: [String: [String]]
        public let note: String?

        public init(
            rowName: String,
            sourceSequenceName: String,
            sourceFilePath: String,
            sourceTrackID: String,
            sourceTrackName: String,
            sourceAnnotationID: String,
            name: String,
            type: String,
            strand: String,
            intervals: [AnnotationInterval],
            qualifiers: [String: [String]] = [:],
            note: String? = nil
        ) {
            self.rowName = rowName
            self.sourceSequenceName = sourceSequenceName
            self.sourceFilePath = sourceFilePath
            self.sourceTrackID = sourceTrackID
            self.sourceTrackName = sourceTrackName
            self.sourceAnnotationID = sourceAnnotationID
            self.name = name
            self.type = type
            self.strand = strand
            self.intervals = intervals
            self.qualifiers = qualifiers
            self.note = note
        }
    }

    public struct ProjectionMetadata: Codable, Sendable, Equatable {
        public let sourceRowID: String
        public let sourceRowName: String
        public let targetRowID: String
        public let targetRowName: String
        public let conflictPolicy: AnnotationProjectionConflictPolicy
        public let validationStatus: String
    }

    public struct AlignmentAnnotationRecord: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let origin: AnnotationOrigin
        public let rowID: String
        public let rowName: String
        public let sourceSequenceName: String
        public let sourceFilePath: String
        public let sourceTrackID: String
        public let sourceTrackName: String
        public let sourceAnnotationID: String
        public let name: String
        public let type: String
        public let strand: String
        public let sourceIntervals: [AnnotationInterval]
        public let alignedIntervals: [AnnotationInterval]
        public let qualifiers: [String: [String]]
        public let note: String?
        public let projection: ProjectionMetadata?
        public let warnings: [String]

        public init(
            id: String,
            origin: AnnotationOrigin,
            rowID: String,
            rowName: String,
            sourceSequenceName: String,
            sourceFilePath: String,
            sourceTrackID: String,
            sourceTrackName: String,
            sourceAnnotationID: String,
            name: String,
            type: String,
            strand: String,
            sourceIntervals: [AnnotationInterval],
            alignedIntervals: [AnnotationInterval],
            qualifiers: [String: [String]],
            note: String?,
            projection: ProjectionMetadata?,
            warnings: [String]
        ) {
            self.id = id
            self.origin = origin
            self.rowID = rowID
            self.rowName = rowName
            self.sourceSequenceName = sourceSequenceName
            self.sourceFilePath = sourceFilePath
            self.sourceTrackID = sourceTrackID
            self.sourceTrackName = sourceTrackName
            self.sourceAnnotationID = sourceAnnotationID
            self.name = name
            self.type = type
            self.strand = strand
            self.sourceIntervals = sourceIntervals
            self.alignedIntervals = alignedIntervals
            self.qualifiers = qualifiers
            self.note = note
            self.projection = projection
            self.warnings = warnings
        }
    }

    public struct AnnotationStore: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let sourceAnnotations: [AlignmentAnnotationRecord]
        public let projectedAnnotations: [AlignmentAnnotationRecord]

        public init(
            schemaVersion: Int = 1,
            sourceAnnotations: [AlignmentAnnotationRecord] = [],
            projectedAnnotations: [AlignmentAnnotationRecord] = []
        ) {
            self.schemaVersion = schemaVersion
            self.sourceAnnotations = sourceAnnotations
            self.projectedAnnotations = projectedAnnotations
        }

        public var allAnnotations: [AlignmentAnnotationRecord] {
            sourceAnnotations + projectedAnnotations
        }
    }

    public struct FASTQQualitySummaryInput: Codable, Sendable, Equatable {
        public let rowName: String
        public let recordID: String
        public let sourceFASTQPath: String
        public let sequenceChecksumSHA256: String
        public let minimumQuality: Int
        public let meanQuality: Double
        public let maximumQuality: Int

        public init(
            rowName: String,
            recordID: String,
            sourceFASTQPath: String,
            sequenceChecksumSHA256: String,
            minimumQuality: Int,
            meanQuality: Double,
            maximumQuality: Int
        ) {
            self.rowName = rowName
            self.recordID = recordID
            self.sourceFASTQPath = sourceFASTQPath
            self.sequenceChecksumSHA256 = sequenceChecksumSHA256
            self.minimumQuality = minimumQuality
            self.meanQuality = meanQuality
            self.maximumQuality = maximumQuality
        }
    }

    public struct FASTQQualityStore: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let records: [FASTQQualitySummaryInput]

        public init(schemaVersion: Int = 1, records: [FASTQQualitySummaryInput] = []) {
            self.schemaVersion = schemaVersion
            self.records = records
        }
    }

    public struct AnnotationEditProvenance: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let workflowName: String
        public let toolName: String
        public let toolVersion: String
        public let argv: [String]
        public let reproducibleCommand: String
        public let editDescription: String
        public let bundlePath: String
        public let input: FileRecord
        public let output: FileRecord
        public let files: [String: FileRecord]
        public let exitStatus: Int
        public let wallTimeSeconds: Double
        public let createdAt: Date
    }

    public struct Provenance: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let workflowName: String
        public let toolName: String
        public let toolVersion: String
        public let argv: [String]
        public let reproducibleCommand: String
        public let options: ProvenanceOptions
        public let runtimeIdentity: RuntimeIdentity
        public let input: FileRecord
        public let output: FileRecord
        public let files: [String: FileRecord]
        public let exitStatus: Int
        public let wallTimeSeconds: Double
        public let warnings: [String]
        public let stderr: String?
        public let createdAt: Date
        public let externalToolInvocations: [ToolInvocation]?
        public let inputFiles: [FileRecord]?
    }

    public struct ToolInvocation: Codable, Sendable, Equatable {
        public let name: String
        public let version: String?
        public let argv: [String]
        public let reproducibleCommand: String
        public let condaEnvironment: String?
        public let executablePath: String?
        public let exitStatus: Int
        public let wallTimeSeconds: Double
        public let stdout: String?
        public let stderr: String?

        public init(
            name: String,
            version: String?,
            argv: [String],
            reproducibleCommand: String,
            condaEnvironment: String?,
            executablePath: String?,
            exitStatus: Int,
            wallTimeSeconds: Double,
            stdout: String?,
            stderr: String?
        ) {
            self.name = name
            self.version = version
            self.argv = argv
            self.reproducibleCommand = reproducibleCommand
            self.condaEnvironment = condaEnvironment
            self.executablePath = executablePath
            self.exitStatus = exitStatus
            self.wallTimeSeconds = wallTimeSeconds
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public struct ProvenanceOptions: Codable, Sendable, Equatable {
        public let name: String?
        public let sourceFormat: String
        public let resolvedSourceFormat: SourceFormat
        public let gapAlphabet: [String]
        public let writeViewState: Bool
        public let writeSQLiteIndex: Bool
    }

    public struct RuntimeIdentity: Codable, Sendable, Equatable {
        public let executablePath: String?
        public let operatingSystemVersion: String
        public let processIdentifier: Int32
        public let condaEnvironment: String?
        public let containerImage: String?
    }

    public struct FileRecord: Codable, Sendable, Equatable {
        public let path: String
        public let checksumSHA256: String
        public let fileSize: Int64
    }

    public enum ImportError: Error, LocalizedError, Sendable {
        case unsupportedFormat(String)
        case emptyAlignment
        case malformedInput(String)
        case unequalAlignedLengths([(String, Int)])
        case sqliteError(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let value):
                return "Unsupported multiple sequence alignment format: \(value)"
            case .emptyAlignment:
                return "Alignment contains no rows."
            case .malformedInput(let reason):
                return "Malformed alignment input: \(reason)"
            case .unequalAlignedLengths(let lengths):
                let summary = lengths.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
                return "Alignment rows have unequal aligned lengths: \(summary)"
            case .sqliteError(let message):
                return "Could not write alignment cache database: \(message)"
            }
        }
    }

    private struct ParsedRow {
        let name: String
        var sequence: String
    }

    public static func load(from url: URL) throws -> MultipleSequenceAlignmentBundle {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let rowsURL = url.appendingPathComponent("metadata/rows.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let rows = try decoder.decode([Row].self, from: Data(contentsOf: rowsURL))
        return MultipleSequenceAlignmentBundle(url: url, manifest: manifest, rows: rows)
    }

    public func loadCoordinateMaps() throws -> [RowCoordinateMap] {
        let mapsURL = url.appendingPathComponent("metadata/coordinate-maps.json")
        guard FileManager.default.fileExists(atPath: mapsURL.path) else { return [] }
        return try Self.decode([RowCoordinateMap].self, from: mapsURL)
    }

    public func loadSourceRowMetadata() throws -> [SourceRowMetadata] {
        let metadataURL = url.appendingPathComponent("metadata/source-row-map.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return [] }
        return try Self.decode([SourceRowMetadata].self, from: metadataURL)
    }

    public func loadAnnotationStore() throws -> AnnotationStore {
        let annotationsSQLiteURL = url.appendingPathComponent(Self.annotationSQLiteRelativePath)
        if FileManager.default.fileExists(atPath: annotationsSQLiteURL.path) {
            return try Self.readAnnotationSQLiteStore(from: annotationsSQLiteURL)
        }
        let annotationsURL = url.appendingPathComponent(Self.annotationJSONRelativePath)
        guard FileManager.default.fileExists(atPath: annotationsURL.path) else {
            return AnnotationStore()
        }
        return try Self.decode(AnnotationStore.self, from: annotationsURL)
    }

    public func loadFASTQQualityStore() throws -> FASTQQualityStore {
        let qualityURL = url.appendingPathComponent("metadata/fastq-quality.json")
        guard FileManager.default.fileExists(atPath: qualityURL.path) else {
            return FASTQQualityStore()
        }
        return try Self.decode(FASTQQualityStore.self, from: qualityURL)
    }

    public func makeAnnotationFromAlignedSelection(
        rowID: String,
        alignedIntervals: [AnnotationInterval],
        name: String,
        type: String,
        strand: String = ".",
        qualifiers: [String: [String]] = [:],
        note: String? = nil
    ) throws -> AlignmentAnnotationRecord {
        guard let row = rows.first(where: { $0.id == rowID }) else {
            throw ImportError.malformedInput("No alignment row with ID \(rowID).")
        }
        let coordinateMaps = try loadCoordinateMaps()
        guard let coordinateMap = coordinateMaps.first(where: { $0.rowID == rowID }) else {
            throw ImportError.malformedInput("No coordinate map for row \(row.displayName).")
        }
        let sourceIntervals = Self.mapAlignedIntervalsToUngappedIntervals(
            alignedIntervals,
            targetMap: coordinateMap
        )
        guard !sourceIntervals.isEmpty else {
            throw ImportError.malformedInput("Selected alignment columns do not contain bases for row \(row.displayName).")
        }
        let normalizedAlignedIntervals = Self.mapUngappedIntervalsToAlignedIntervals(
            sourceIntervals,
            coordinateMap: coordinateMap
        )
        let annotationID = "manual-\(UUID().uuidString)"
        return AlignmentAnnotationRecord(
            id: "manual-\(annotationID)-\(row.id)",
            origin: .manual,
            rowID: row.id,
            rowName: row.displayName,
            sourceSequenceName: row.sourceName,
            sourceFilePath: url.path,
            sourceTrackID: "msa-user-annotations",
            sourceTrackName: "MSA User Annotations",
            sourceAnnotationID: annotationID,
            name: name,
            type: type,
            strand: strand,
            sourceIntervals: sourceIntervals,
            alignedIntervals: normalizedAlignedIntervals,
            qualifiers: qualifiers,
            note: note,
            projection: nil,
            warnings: []
        )
    }

    @discardableResult
    public func appendingAnnotations(
        _ newAnnotations: [AlignmentAnnotationRecord],
        editDescription: String,
        argv: [String],
        workflowName: String = "multiple-sequence-alignment-annotation-edit",
        toolName: String = "lungfish-gui msa annotation edit"
    ) throws -> MultipleSequenceAlignmentBundle {
        guard !newAnnotations.isEmpty else { return self }
        var store = try loadAnnotationStore()
        var sourceAnnotations = store.sourceAnnotations
        var projectedAnnotations = store.projectedAnnotations
        for annotation in newAnnotations {
            switch annotation.origin {
            case .projected:
                projectedAnnotations.removeAll { $0.id == annotation.id }
                projectedAnnotations.append(annotation)
            case .source, .manual:
                sourceAnnotations.removeAll { $0.id == annotation.id }
                sourceAnnotations.append(annotation)
            }
        }
        sourceAnnotations.sort { lhs, rhs in
            lhs.rowName == rhs.rowName ? lhs.name < rhs.name : lhs.rowName < rhs.rowName
        }
        projectedAnnotations.sort { lhs, rhs in
            lhs.rowName == rhs.rowName ? lhs.name < rhs.name : lhs.rowName < rhs.rowName
        }

        store = AnnotationStore(
            schemaVersion: store.schemaVersion,
            sourceAnnotations: sourceAnnotations,
            projectedAnnotations: projectedAnnotations
        )
        return try replacingAnnotationStore(
            store,
            editDescription: editDescription,
            argv: argv,
            workflowName: workflowName,
            toolName: toolName
        )
    }

    @discardableResult
    public func replacingAnnotationStore(
        _ store: AnnotationStore,
        editDescription: String,
        argv: [String],
        workflowName: String = "multiple-sequence-alignment-annotation-edit",
        toolName: String = "lungfish-gui msa annotation edit"
    ) throws -> MultipleSequenceAlignmentBundle {
        let startedAt = Date()
        let annotationsURL = url.appendingPathComponent("metadata/annotations.json")
        let annotationsSQLiteURL = url.appendingPathComponent(Self.annotationSQLiteRelativePath)
        let editProvenanceURL = url.appendingPathComponent("metadata/annotation-edit-provenance.json")
        let manifestURL = url.appendingPathComponent("manifest.json")

        let sourceAnnotations = store.sourceAnnotations.sorted { lhs, rhs in
            lhs.rowName == rhs.rowName ? lhs.name < rhs.name : lhs.rowName < rhs.rowName
        }
        let projectedAnnotations = store.projectedAnnotations.sorted { lhs, rhs in
            lhs.rowName == rhs.rowName ? lhs.name < rhs.name : lhs.rowName < rhs.rowName
        }
        let normalizedStore = AnnotationStore(
            schemaVersion: store.schemaVersion,
            sourceAnnotations: sourceAnnotations,
            projectedAnnotations: projectedAnnotations
        )
        try Self.encode(normalizedStore, to: annotationsURL)
        try Self.writeAnnotationSQLiteStore(normalizedStore, to: annotationsSQLiteURL)

        let provenance = AnnotationEditProvenance(
            schemaVersion: 1,
            workflowName: workflowName,
            toolName: toolName,
            toolVersion: Self.toolVersion,
            argv: argv,
            reproducibleCommand: Self.shellCommand(from: argv),
            editDescription: editDescription,
            bundlePath: url.path,
            input: try Self.fileRecord(for: url),
            output: try Self.fileRecord(for: annotationsSQLiteURL),
            files: [
                "metadata/annotations.json": try Self.fileRecord(for: annotationsURL),
                Self.annotationSQLiteRelativePath: try Self.fileRecord(for: annotationsSQLiteURL),
            ],
            exitStatus: 0,
            wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt)),
            createdAt: Date()
        )
        try Self.encode(provenance, to: editProvenanceURL)

        var capabilities = Set(manifest.capabilities)
        if !normalizedStore.allAnnotations.isEmpty {
            capabilities.insert("annotation-retention")
            capabilities.insert("annotation-projection")
        } else {
            capabilities.remove("annotation-retention")
            capabilities.remove("annotation-projection")
            capabilities.remove("annotation-authoring")
        }
        if normalizedStore.sourceAnnotations.contains(where: { $0.origin == .manual }) {
            capabilities.insert("annotation-authoring")
        } else {
            capabilities.remove("annotation-authoring")
        }

        var checksums = manifest.checksums
        var fileSizes = manifest.fileSizes
        for relativePath in [Self.annotationJSONRelativePath, Self.annotationSQLiteRelativePath, "metadata/annotation-edit-provenance.json"] {
            let fileURL = url.appendingPathComponent(relativePath)
            checksums[relativePath] = try Self.checksum(at: fileURL)
            fileSizes[relativePath] = try Self.fileSize(at: fileURL)
        }

        let updatedManifest = manifest.copying(
            capabilities: capabilities.sorted(),
            checksums: checksums,
            fileSizes: fileSizes
        )
        try Self.encode(updatedManifest, to: manifestURL)
        return try Self.load(from: url)
    }

    public static func projectAnnotation(
        _ annotation: AlignmentAnnotationRecord,
        to targetMap: RowCoordinateMap,
        conflictPolicy: AnnotationProjectionConflictPolicy
    ) -> AlignmentAnnotationRecord {
        let projectedIntervals = mapAlignedIntervalsToUngappedIntervals(
            annotation.alignedIntervals,
            targetMap: targetMap
        )
        var warnings: [String] = []
        if projectedIntervals.isEmpty {
            warnings.append("Projection produced no target bases; selected annotation aligns entirely to target gaps.")
        }
        if projectedIntervals.count > 1 {
            warnings.append("Projection split into \(projectedIntervals.count) intervals because gaps or unaligned columns interrupt the target feature.")
        }
        let projection = ProjectionMetadata(
            sourceRowID: annotation.rowID,
            sourceRowName: annotation.rowName,
            targetRowID: targetMap.rowID,
            targetRowName: targetMap.rowName,
            conflictPolicy: conflictPolicy,
            validationStatus: warnings.isEmpty ? "valid" : "warning"
        )
        return AlignmentAnnotationRecord(
            id: "projected-\(annotation.sourceAnnotationID)-to-\(targetMap.rowID)",
            origin: .projected,
            rowID: targetMap.rowID,
            rowName: targetMap.rowName,
            sourceSequenceName: targetMap.rowName,
            sourceFilePath: annotation.sourceFilePath,
            sourceTrackID: annotation.sourceTrackID,
            sourceTrackName: annotation.sourceTrackName,
            sourceAnnotationID: annotation.sourceAnnotationID,
            name: annotation.name,
            type: annotation.type,
            strand: annotation.strand,
            sourceIntervals: projectedIntervals,
            alignedIntervals: annotation.alignedIntervals,
            qualifiers: annotation.qualifiers,
            note: annotation.note,
            projection: projection,
            warnings: annotation.warnings + warnings
        )
    }

    @discardableResult
    public static func importAlignment(
        from inputURL: URL,
        to bundleURL: URL,
        options: ImportOptions = ImportOptions()
    ) throws -> MultipleSequenceAlignmentBundle {
        let startedAt = Date()
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            throw ImportError.malformedInput("Output bundle already exists: \(bundleURL.path)")
        }

        let sourceData = try Data(contentsOf: inputURL)
        guard let sourceText = String(data: sourceData, encoding: .utf8) else {
            throw ImportError.malformedInput("Input is not valid UTF-8 text.")
        }

        let sourceFormat = try options.sourceFormat ?? detectFormat(for: inputURL, sourceText: sourceText)
        let parsedRows = try parse(sourceText, format: sourceFormat)
        try validateRectangular(parsedRows)

        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        do {
            try writeBundle(
                parsedRows: parsedRows,
                sourceData: sourceData,
                inputURL: inputURL,
                bundleURL: bundleURL,
                sourceFormat: sourceFormat,
                options: options,
                startedAt: startedAt
            )
            return try load(from: bundleURL)
        } catch {
            try? fm.removeItem(at: bundleURL)
            throw error
        }
    }

    public static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func fileRecordForProvenance(at url: URL) throws -> FileRecord {
        try fileRecord(for: url)
    }

    private static func writeBundle(
        parsedRows: [ParsedRow],
        sourceData: Data,
        inputURL: URL,
        bundleURL: URL,
        sourceFormat: SourceFormat,
        options: ImportOptions,
        startedAt: Date
    ) throws {
        let fm = FileManager.default
        let alignmentDir = bundleURL.appendingPathComponent("alignment", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        let cacheDir = bundleURL.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: alignmentDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let sourceURL = alignmentDir.appendingPathComponent("source.original")
        let primaryURL = alignmentDir.appendingPathComponent("primary.aligned.fasta")
        let rowsURL = metadataDir.appendingPathComponent("rows.json")
        let coordinateMapsURL = metadataDir.appendingPathComponent("coordinate-maps.json")
        let sourceRowMapURL = metadataDir.appendingPathComponent("source-row-map.json")
        let annotationsURL = metadataDir.appendingPathComponent("annotations.json")
        let annotationsSQLiteURL = metadataDir.appendingPathComponent("annotations.sqlite")
        let fastqQualityURL = metadataDir.appendingPathComponent("fastq-quality.json")
        let indexURL = cacheDir.appendingPathComponent("alignment-index.sqlite")
        let viewStateURL = bundleURL.appendingPathComponent(".viewstate.json")
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")

        try sourceData.write(to: sourceURL, options: .atomic)
        let normalizedFASTA = normalizedFASTA(for: parsedRows)
        try Data(normalizedFASTA.utf8).write(to: primaryURL, options: .atomic)
        for file in options.additionalFiles {
            let destination = bundleURL.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: file.sourceURL, to: destination)
        }

        let alphabet = inferAlphabet(parsedRows.map(\.sequence).joined())
        let rows = parsedRows.enumerated().map { index, parsed in
            let rowAlphabet = inferAlphabet(parsed.sequence)
            let gapCount = parsed.sequence.reduce(0) { $0 + (isGap($1) ? 1 : 0) }
            let ungapped = parsed.sequence.filter { !isGap($0) }
            return Row(
                id: rowID(order: index, name: parsed.name),
                sourceName: parsed.name,
                displayName: parsed.name,
                order: index,
                alphabet: rowAlphabet,
                alignedLength: parsed.sequence.count,
                ungappedLength: ungapped.count,
                gapCount: gapCount,
                ambiguousCount: ungapped.reduce(0) { $0 + (isAmbiguous($1, alphabet: rowAlphabet) ? 1 : 0) },
                checksumSHA256: sha256Hex(for: Data(parsed.sequence.utf8)),
                accession: nil,
                organism: nil,
                geneProduct: nil,
                haplotypeClade: nil,
                metadata: [:]
            )
        }
        try encode(rows, to: rowsURL)
        let coordinateMaps = makeCoordinateMaps(parsedRows: parsedRows, rows: rows)
        try encode(coordinateMaps, to: coordinateMapsURL)
        let sourceRowMetadata = makeSourceRowMetadata(rows: rows, options: options, inputURL: inputURL, parsedRows: parsedRows)
        try encode(sourceRowMetadata, to: sourceRowMapURL)
        let annotationStore = makeAnnotationStore(
            sourceAnnotations: options.sourceAnnotations,
            rows: rows,
            coordinateMaps: coordinateMaps
        )
        try encode(annotationStore, to: annotationsURL)
        try writeAnnotationSQLiteStore(annotationStore, to: annotationsSQLiteURL)
        if !options.fastqQualitySummaries.isEmpty {
            try encode(FASTQQualityStore(records: options.fastqQualitySummaries), to: fastqQualityURL)
        }

        let columnStats = computeColumnStats(parsedRows)
        let warnings = warnings(for: parsedRows, sourceFormat: sourceFormat) + options.extraWarnings
        try writeSQLiteIndex(at: indexURL, rows: rows, columns: columnStats)
        try writeViewState(to: viewStateURL, referenceRowID: rows.first?.id)
        if let analysisToolName = options.analysisToolName {
            try AnalysesFolder.writeAnalysisMetadata(
                .init(tool: analysisToolName, isBatch: false, created: startedAt),
                to: bundleURL
            )
        }

        let bundleRelativePaths = [
            "alignment/primary.aligned.fasta",
            "alignment/source.original",
            "metadata/rows.json",
            "metadata/coordinate-maps.json",
            "metadata/source-row-map.json",
            "metadata/annotations.json",
            Self.annotationSQLiteRelativePath,
            "cache/alignment-index.sqlite",
            ".viewstate.json",
        ]
            + (options.analysisToolName == nil ? [] : [AnalysesFolder.metadataFilename])
            + (options.fastqQualitySummaries.isEmpty ? [] : ["metadata/fastq-quality.json"])
            + options.additionalFiles.map(\.relativePath)

        var checksums: [String: String] = [:]
        var sizes: [String: Int64] = [:]
        for relativePath in bundleRelativePaths {
            let fileURL = bundleURL.appendingPathComponent(relativePath)
            checksums[relativePath] = try checksum(at: fileURL)
            sizes[relativePath] = try fileSize(at: fileURL)
        }

        var capabilities = [
            "alignment-grid",
            "consensus",
            "row-statistics",
            "variable-sites",
            "parsimony-informative-sites",
            "export-fasta",
            "coordinate-maps",
        ]
        if !annotationStore.allAnnotations.isEmpty {
            capabilities.append("annotation-retention")
            capabilities.append("annotation-projection")
        }
        capabilities.append("sqlite-backed-annotations")
        if !options.fastqQualitySummaries.isEmpty {
            capabilities.append("fastq-quality-sidecar")
        }
        capabilities.append(contentsOf: options.extraCapabilities)
        capabilities = Array(Set(capabilities)).sorted()

        let manifest = Manifest(
            schemaVersion: 1,
            bundleKind: "multiple-sequence-alignment",
            identifier: UUID().uuidString,
            name: options.name ?? inputURL.deletingPathExtension().lastPathComponent,
            createdAt: startedAt,
            sourceFormat: sourceFormat,
            sourceFileName: inputURL.lastPathComponent,
            rowCount: rows.count,
            alignedLength: parsedRows.first?.sequence.count ?? 0,
            alphabet: alphabet,
            gapAlphabet: options.gapAlphabet,
            referenceRowID: rows.first?.id,
            warnings: warnings,
            capabilities: capabilities,
            consensus: columnStats.map(\.consensusResidue).joined(),
            variableSiteCount: columnStats.filter(\.variableSite).count,
            parsimonyInformativeSiteCount: columnStats.filter(\.parsimonyInformative).count,
            checksums: checksums,
            fileSizes: sizes
        )
        try encode(manifest, to: manifestURL)

        let allFileRecords = try fileRecords(
            bundleURL: bundleURL,
            relativePaths: ["manifest.json"] + bundleRelativePaths
        )
        let bundleChecksums = allFileRecords.mapValues(\.checksumSHA256)
        let provenanceInputFiles = options.inputFiles.isEmpty
            ? [try fileRecord(for: inputURL)]
            : options.inputFiles
        let provenance = Provenance(
            schemaVersion: 1,
            workflowName: options.workflowName,
            toolName: options.toolName,
            toolVersion: options.toolVersion,
            argv: options.argv ?? defaultArgv(inputURL: inputURL, bundleURL: bundleURL, name: manifest.name),
            reproducibleCommand: options.reproducibleCommand
                ?? shellCommand(from: options.argv ?? defaultArgv(inputURL: inputURL, bundleURL: bundleURL, name: manifest.name)),
            options: ProvenanceOptions(
                name: options.name,
                sourceFormat: options.sourceFormat?.rawValue ?? "auto",
                resolvedSourceFormat: sourceFormat,
                gapAlphabet: options.gapAlphabet,
                writeViewState: true,
                writeSQLiteIndex: true
            ),
            runtimeIdentity: RuntimeIdentity(
                executablePath: ProcessInfo.processInfo.arguments.first,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                condaEnvironment: ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"],
                containerImage: ProcessInfo.processInfo.environment["LUNGFISH_CONTAINER_IMAGE"]
            ),
            input: try fileRecord(for: sourceURL),
            output: FileRecord(
                path: bundleURL.path,
                checksumSHA256: bundleDigest(checksums: bundleChecksums),
                fileSize: try directorySize(at: bundleURL)
            ),
            files: allFileRecords,
            exitStatus: 0,
            wallTimeSeconds: options.wallTimeSeconds ?? max(0, Date().timeIntervalSince(startedAt)),
            warnings: warnings,
            stderr: options.stderr ?? (warnings.isEmpty ? nil : warnings.joined(separator: "\n")),
            createdAt: Date(),
            externalToolInvocations: options.externalToolInvocations.isEmpty ? nil : options.externalToolInvocations,
            inputFiles: provenanceInputFiles
        )
        try encode(provenance, to: provenanceURL)
    }

    private static func makeCoordinateMaps(parsedRows: [ParsedRow], rows: [Row]) -> [RowCoordinateMap] {
        zip(parsedRows, rows).map { parsed, row in
            var alignmentToUngapped: [Int?] = []
            var ungappedToAlignment: [Int] = []
            var ungappedIndex = 0
            for (alignmentIndex, residue) in parsed.sequence.enumerated() {
                if isGap(residue) {
                    alignmentToUngapped.append(nil)
                } else {
                    alignmentToUngapped.append(ungappedIndex)
                    ungappedToAlignment.append(alignmentIndex)
                    ungappedIndex += 1
                }
            }
            return RowCoordinateMap(
                rowID: row.id,
                rowName: parsed.name,
                alignedLength: parsed.sequence.count,
                ungappedLength: ungappedIndex,
                alignmentToUngapped: alignmentToUngapped,
                ungappedToAlignment: ungappedToAlignment
            )
        }
    }

    private static func makeSourceRowMetadata(
        rows: [Row],
        options: ImportOptions,
        inputURL: URL,
        parsedRows: [ParsedRow]
    ) -> [SourceRowMetadata] {
        var metadataByRowName: [String: SourceRowMetadataInput] = [:]
        for source in options.sourceRowMetadata where metadataByRowName[source.rowName] == nil {
            metadataByRowName[source.rowName] = source
        }
        return zip(rows, parsedRows).map { row, parsed in
            if let source = metadataByRowName[parsed.name] {
                return SourceRowMetadata(
                    rowID: row.id,
                    rowName: parsed.name,
                    originalName: source.originalName,
                    sourceSequenceName: source.sourceSequenceName,
                    sourceFilePath: source.sourceFilePath,
                    sourceFormat: source.sourceFormat,
                    sourceChecksumSHA256: source.sourceChecksumSHA256
                )
            }
            let ungapped = parsed.sequence.filter { !isGap($0) }
            return SourceRowMetadata(
                rowID: row.id,
                rowName: parsed.name,
                originalName: parsed.name,
                sourceSequenceName: parsed.name,
                sourceFilePath: inputURL.path,
                sourceFormat: "alignment-row",
                sourceChecksumSHA256: sha256Hex(for: Data(String(ungapped).utf8))
            )
        }
    }

    private static func makeAnnotationStore(
        sourceAnnotations: [SourceAnnotationInput],
        rows: [Row],
        coordinateMaps: [RowCoordinateMap]
    ) -> AnnotationStore {
        guard !sourceAnnotations.isEmpty else {
            return AnnotationStore()
        }
        var rowsByName: [String: Row] = [:]
        for row in rows where rowsByName[row.displayName] == nil {
            rowsByName[row.displayName] = row
        }
        var mapsByName: [String: RowCoordinateMap] = [:]
        for coordinateMap in coordinateMaps where mapsByName[coordinateMap.rowName] == nil {
            mapsByName[coordinateMap.rowName] = coordinateMap
        }
        let records = sourceAnnotations.compactMap { source -> AlignmentAnnotationRecord? in
            guard let row = rowsByName[source.rowName],
                  let coordinateMap = mapsByName[source.rowName] else {
                return nil
            }
            let alignedIntervals = mapUngappedIntervalsToAlignedIntervals(
                source.intervals,
                coordinateMap: coordinateMap
            )
            var warnings: [String] = []
            if alignedIntervals.isEmpty {
                warnings.append("Source annotation \(source.sourceAnnotationID) did not overlap any aligned bases.")
            } else if alignedIntervals.count > source.intervals.count {
                warnings.append("Source annotation \(source.sourceAnnotationID) was split into \(alignedIntervals.count) aligned intervals by gaps.")
            }
            return AlignmentAnnotationRecord(
                id: "source-\(source.sourceAnnotationID)-\(row.id)",
                origin: .source,
                rowID: row.id,
                rowName: source.rowName,
                sourceSequenceName: source.sourceSequenceName,
                sourceFilePath: source.sourceFilePath,
                sourceTrackID: source.sourceTrackID,
                sourceTrackName: source.sourceTrackName,
                sourceAnnotationID: source.sourceAnnotationID,
                name: source.name,
                type: source.type,
                strand: source.strand,
                sourceIntervals: source.intervals,
                alignedIntervals: alignedIntervals,
                qualifiers: source.qualifiers,
                note: source.note,
                projection: nil,
                warnings: warnings
            )
        }
        return AnnotationStore(sourceAnnotations: records)
    }

    private static func mapUngappedIntervalsToAlignedIntervals(
        _ intervals: [AnnotationInterval],
        coordinateMap: RowCoordinateMap
    ) -> [AnnotationInterval] {
        var alignedColumns: [Int] = []
        for interval in intervals {
            guard interval.start < interval.end else { continue }
            for ungappedCoordinate in interval.start..<interval.end {
                guard coordinateMap.ungappedToAlignment.indices.contains(ungappedCoordinate) else { continue }
                alignedColumns.append(coordinateMap.ungappedToAlignment[ungappedCoordinate])
            }
        }
        return collapseCoordinatesToIntervals(alignedColumns)
    }

    private static func mapAlignedIntervalsToUngappedIntervals(
        _ intervals: [AnnotationInterval],
        targetMap: RowCoordinateMap
    ) -> [AnnotationInterval] {
        var ungappedCoordinates: [Int] = []
        for interval in intervals {
            guard interval.start < interval.end else { continue }
            for alignmentColumn in interval.start..<interval.end {
                guard targetMap.alignmentToUngapped.indices.contains(alignmentColumn),
                      let ungapped = targetMap.alignmentToUngapped[alignmentColumn] else {
                    continue
                }
                ungappedCoordinates.append(ungapped)
            }
        }
        return collapseCoordinatesToIntervals(ungappedCoordinates)
    }

    private static func collapseCoordinatesToIntervals(_ coordinates: [Int]) -> [AnnotationInterval] {
        let sorted = Array(Set(coordinates)).sorted()
        guard let first = sorted.first else { return [] }
        var intervals: [AnnotationInterval] = []
        var start = first
        var previous = first
        for coordinate in sorted.dropFirst() {
            if coordinate == previous + 1 {
                previous = coordinate
            } else {
                intervals.append(AnnotationInterval(start: start, end: previous + 1))
                start = coordinate
                previous = coordinate
            }
        }
        intervals.append(AnnotationInterval(start: start, end: previous + 1))
        return intervals
    }

    private static func detectFormat(for url: URL, sourceText: String) throws -> SourceFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "fa", "fasta", "fas", "fna", "faa":
            return .alignedFASTA
        case "aln", "clustal", "clw":
            return .clustal
        case "phy", "phylip":
            return .phylip
        case "nex", "nexus":
            return .nexus
        case "sto", "stockholm":
            return .stockholm
        case "a2m", "a3m":
            return .a2mA3m
        default:
            let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(">") { return .alignedFASTA }
            if trimmed.uppercased().hasPrefix("CLUSTAL") { return .clustal }
            if trimmed.uppercased().hasPrefix("#NEXUS") { return .nexus }
            if trimmed.uppercased().hasPrefix("# STOCKHOLM") { return .stockholm }
            throw ImportError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ext)
        }
    }

    private static func parse(_ text: String, format: SourceFormat) throws -> [ParsedRow] {
        switch format {
        case .alignedFASTA, .a2mA3m:
            return try parseFASTA(text)
        case .clustal:
            return try parseBlockedRows(text, skip: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty
                    || trimmed.uppercased().hasPrefix("CLUSTAL")
                    || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix(":")
                    || trimmed.hasPrefix(".")
                    || line.first?.isWhitespace == true && trimmed.allSatisfy { "*:. ".contains($0) }
            })
        case .phylip:
            return try parsePHYLIP(text)
        case .nexus:
            return try parseNEXUS(text)
        case .stockholm:
            return try parseBlockedRows(text, skip: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "//"
            })
        }
    }

    private static func parseFASTA(_ text: String) throws -> [ParsedRow] {
        var rows: [ParsedRow] = []
        var currentName: String?
        var currentSequence = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                if let name = currentName {
                    rows.append(ParsedRow(name: name, sequence: currentSequence))
                }
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ImportError.malformedInput("FASTA row header is empty.") }
                currentName = name
                currentSequence = ""
            } else {
                guard currentName != nil else {
                    throw ImportError.malformedInput("FASTA sequence appears before the first header.")
                }
                currentSequence += line.filter { !$0.isWhitespace }
            }
        }
        if let name = currentName {
            rows.append(ParsedRow(name: name, sequence: currentSequence))
        }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        guard rows.allSatisfy({ !$0.sequence.isEmpty }) else {
            throw ImportError.malformedInput("FASTA contains an empty aligned row.")
        }
        return rows
    }

    private static func parseBlockedRows(_ text: String, skip: (String) -> Bool) throws -> [ParsedRow] {
        var order: [String] = []
        var sequences: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            if skip(rawLine) { continue }
            let parts = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let segment = parts[1]
            if sequences[name] == nil {
                order.append(name)
                sequences[name] = segment
            } else {
                sequences[name, default: ""] += segment
            }
        }
        let rows = order.compactMap { name in sequences[name].map { ParsedRow(name: name, sequence: $0) } }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        return rows
    }

    private static func parsePHYLIP(_ text: String) throws -> [ParsedRow] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { throw ImportError.emptyAlignment }
        let headerParts = header.split(whereSeparator: \.isWhitespace)
        guard headerParts.count >= 2,
              let expectedRows = Int(headerParts[0]),
              let expectedLength = Int(headerParts[1]) else {
            throw ImportError.malformedInput("PHYLIP header must contain row count and aligned length.")
        }
        let body = Array(lines.dropFirst())
        var rows: [ParsedRow] = []
        var index = 0
        while rows.count < expectedRows, index < body.count {
            let parts = body[index].split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first else {
                index += 1
                continue
            }

            var sequence = parts.dropFirst().joined()
            index += 1
            while sequence.count < expectedLength, index < body.count {
                sequence += body[index].filter { !$0.isWhitespace }
                index += 1
            }
            rows.append(ParsedRow(name: name, sequence: sequence))
        }

        guard rows.count == expectedRows else {
            throw ImportError.malformedInput("PHYLIP expected \(expectedRows) rows but found \(rows.count).")
        }
        let badLength = rows.first { $0.sequence.count != expectedLength }
        if let badLength {
            throw ImportError.malformedInput("PHYLIP row \(badLength.name) length does not match header nchar \(expectedLength).")
        }
        return rows
    }

    private static func parseNEXUS(_ text: String) throws -> [ParsedRow] {
        var inMatrix = false
        var matrixLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = rawLine.replacingOccurrences(
                of: #"\[[^\]]*\]"#,
                with: "",
                options: .regularExpression
            )
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !inMatrix {
                if trimmed.lowercased().hasPrefix("matrix") {
                    inMatrix = true
                    let remainder = String(trimmed.dropFirst("matrix".count)).trimmingCharacters(in: .whitespaces)
                    if !remainder.isEmpty { matrixLines.append(remainder) }
                }
            } else if trimmed.hasPrefix(";") {
                break
            } else {
                matrixLines.append(trimmed)
                if trimmed.contains(";") { break }
            }
        }

        let rows = matrixLines.compactMap { line -> ParsedRow? in
            let cleaned = line.replacingOccurrences(of: ";", with: "")
            let parts = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ParsedRow(name: parts[0], sequence: parts.dropFirst().joined())
        }
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        return rows
    }

    private static func validateRectangular(_ rows: [ParsedRow]) throws {
        guard !rows.isEmpty else { throw ImportError.emptyAlignment }
        let lengths = rows.map { ($0.name, $0.sequence.count) }
        guard let expected = lengths.first?.1, lengths.allSatisfy({ $0.1 == expected }) else {
            throw ImportError.unequalAlignedLengths(lengths)
        }
    }

    private static func computeColumnStats(_ rows: [ParsedRow]) -> [ColumnStat] {
        guard let alignedLength = rows.first?.sequence.count else { return [] }
        let rowCharacters = rows.map { Array($0.sequence) }
        return (0..<alignedLength).map { column in
            var counts: [String: Int] = [:]
            var gapCount = 0
            for row in rowCharacters {
                let residue = row[column]
                if isGap(residue) {
                    gapCount += 1
                } else {
                    counts[String(residue).uppercased(), default: 0] += 1
                }
            }
            let nonGapTotal = counts.values.reduce(0, +)
            let consensus = counts.sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }.first?.key ?? "-"
            let maxCount = counts.values.max() ?? 0
            let entropy = counts.values.reduce(0.0) { result, count in
                guard nonGapTotal > 0 else { return result }
                let p = Double(count) / Double(nonGapTotal)
                return result - (p * log2(p))
            }
            let informativeResidues = counts.values.filter { $0 >= 2 }.count
            return ColumnStat(
                index: column,
                consensusResidue: consensus,
                residueCounts: counts,
                gapFraction: Double(gapCount) / Double(rows.count),
                conservation: nonGapTotal == 0 ? 0 : Double(maxCount) / Double(nonGapTotal),
                entropy: entropy,
                variableSite: counts.count > 1,
                parsimonyInformative: informativeResidues >= 2
            )
        }
    }

    private static func normalizedFASTA(for rows: [ParsedRow]) -> String {
        rows.map { row in
            ">\(row.name)\n\(row.sequence)\n"
        }.joined()
    }

    private static func warnings(for rows: [ParsedRow], sourceFormat: SourceFormat) -> [String] {
        var warnings: [String] = []
        if sourceFormat == .a2mA3m, rows.contains(where: { row in row.sequence.contains(where: \.isLowercase) }) {
            warnings.append("A2M/A3M lowercase insert-state residues were preserved as aligned characters.")
        }
        if Set(rows.map(\.name)).count != rows.count {
            warnings.append("Duplicate row names are present; stable row IDs preserve row order.")
        }
        return warnings
    }

    private static func inferAlphabet(_ sequence: String) -> String {
        let residues = Set(sequence.uppercased().filter { !isGap($0) && !$0.isWhitespace })
        if residues.isEmpty { return "unknown" }
        let dna = Set("ACGTUNRYKMSWBDHV?")
        let rna = Set("ACGUNRYKMSWBDHV?")
        if residues.isSubset(of: rna), residues.contains("U"), !residues.contains("T") { return "rna" }
        if residues.isSubset(of: dna) { return "dna" }
        return "protein"
    }

    private static func isGap(_ character: Character) -> Bool {
        character == "-" || character == "."
    }

    private static func isAmbiguous(_ character: Character, alphabet: String) -> Bool {
        let value = String(character).uppercased()
        if value == "?" { return true }
        switch alphabet {
        case "dna":
            return !["A", "C", "G", "T", "U"].contains(value)
        case "rna":
            return !["A", "C", "G", "U"].contains(value)
        case "protein":
            return value == "X" || value == "B" || value == "Z" || value == "J" || value == "O" || value == "U"
        default:
            return false
        }
    }

    private static func rowID(order: Int, name: String) -> String {
        let digest = sha256Hex(for: Data(name.utf8)).prefix(10)
        return "row-\(String(format: "%06d", order + 1))-\(digest)"
    }

    private static func writeViewState(to url: URL, referenceRowID: String?) throws {
        let viewState: [String: Any] = [
            "schemaVersion": 1,
            "scrollColumn": 0,
            "scrollRow": 0,
            "selection": NSNull(),
            "referenceRowID": referenceRowID as Any,
            "colorScheme": "nucleotide",
            "showConsensus": true,
            "showVariableSites": true,
            "filters": [:],
            "visibleTracks": ["consensus"],
        ]
        let data = try JSONSerialization.data(withJSONObject: viewState, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func writeAnnotationSQLiteStore(_ store: AnnotationStore, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open annotations.sqlite failed")
        }
        defer { sqlite3_close_v2(db) }

        try exec("""
        PRAGMA user_version = 1;
        CREATE TABLE annotation_records (
            id TEXT PRIMARY KEY,
            record_order INTEGER NOT NULL,
            origin TEXT NOT NULL,
            row_id TEXT NOT NULL,
            row_name TEXT NOT NULL,
            source_sequence_name TEXT NOT NULL,
            source_file_path TEXT NOT NULL,
            source_track_id TEXT NOT NULL,
            source_track_name TEXT NOT NULL,
            source_annotation_id TEXT NOT NULL,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            strand TEXT NOT NULL,
            source_intervals_json TEXT NOT NULL,
            aligned_intervals_json TEXT NOT NULL,
            qualifiers_json TEXT NOT NULL,
            note TEXT,
            projection_json TEXT,
            warnings_json TEXT NOT NULL
        );
        CREATE TABLE annotation_intervals (
            record_id TEXT NOT NULL,
            coordinate_system TEXT NOT NULL,
            interval_order INTEGER NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            FOREIGN KEY(record_id) REFERENCES annotation_records(id) ON DELETE CASCADE
        );
        CREATE INDEX annotation_records_row_idx ON annotation_records(row_id);
        CREATE INDEX annotation_records_track_idx ON annotation_records(source_track_id);
        CREATE INDEX annotation_records_type_idx ON annotation_records(type);
        CREATE INDEX annotation_intervals_lookup_idx ON annotation_intervals(coordinate_system, start, end);
        """, db: db)

        try exec("BEGIN TRANSACTION", db: db)
        do {
            for (order, record) in store.allAnnotations.enumerated() {
                try execute(
                    """
                    INSERT INTO annotation_records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values: [
                        record.id,
                        order,
                        record.origin.rawValue,
                        record.rowID,
                        record.rowName,
                        record.sourceSequenceName,
                        record.sourceFilePath,
                        record.sourceTrackID,
                        record.sourceTrackName,
                        record.sourceAnnotationID,
                        record.name,
                        record.type,
                        record.strand,
                        try jsonString(record.sourceIntervals),
                        try jsonString(record.alignedIntervals),
                        try jsonString(record.qualifiers),
                        record.note ?? NSNull(),
                        try optionalJSONString(record.projection),
                        try jsonString(record.warnings),
                    ],
                    db: db
                )
                try writeAnnotationIntervals(record.sourceIntervals, recordID: record.id, coordinateSystem: "source", db: db)
                try writeAnnotationIntervals(record.alignedIntervals, recordID: record.id, coordinateSystem: "aligned", db: db)
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func writeAnnotationIntervals(
        _ intervals: [AnnotationInterval],
        recordID: String,
        coordinateSystem: String,
        db: OpaquePointer
    ) throws {
        for (order, interval) in intervals.enumerated() {
            try execute(
                "INSERT INTO annotation_intervals VALUES (?, ?, ?, ?, ?)",
                values: [
                    recordID,
                    coordinateSystem,
                    order,
                    interval.start,
                    interval.end,
                ],
                db: db
            )
        }
    }

    private static func readAnnotationSQLiteStore(from url: URL) throws -> AnnotationStore {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open annotations.sqlite failed")
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
        SELECT origin, row_id, row_name, source_sequence_name, source_file_path,
               source_track_id, source_track_name, source_annotation_id, name, type,
               strand, source_intervals_json, aligned_intervals_json, qualifiers_json,
               note, projection_json, warnings_json, id
        FROM annotation_records
        ORDER BY record_order, row_name, name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sourceAnnotations: [AlignmentAnnotationRecord] = []
        var projectedAnnotations: [AlignmentAnnotationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let origin = AnnotationOrigin(rawValue: columnText(statement, 0)) ?? .source
            let record = AlignmentAnnotationRecord(
                id: columnText(statement, 17),
                origin: origin,
                rowID: columnText(statement, 1),
                rowName: columnText(statement, 2),
                sourceSequenceName: columnText(statement, 3),
                sourceFilePath: columnText(statement, 4),
                sourceTrackID: columnText(statement, 5),
                sourceTrackName: columnText(statement, 6),
                sourceAnnotationID: columnText(statement, 7),
                name: columnText(statement, 8),
                type: columnText(statement, 9),
                strand: columnText(statement, 10),
                sourceIntervals: try valueFromJSONString([AnnotationInterval].self, columnText(statement, 11)),
                alignedIntervals: try valueFromJSONString([AnnotationInterval].self, columnText(statement, 12)),
                qualifiers: try valueFromJSONString([String: [String]].self, columnText(statement, 13)),
                note: columnOptionalText(statement, 14),
                projection: try optionalValueFromJSONString(ProjectionMetadata.self, columnOptionalText(statement, 15)),
                warnings: try valueFromJSONString([String].self, columnText(statement, 16))
            )
            switch origin {
            case .projected:
                projectedAnnotations.append(record)
            case .source, .manual:
                sourceAnnotations.append(record)
            }
        }
        return AnnotationStore(sourceAnnotations: sourceAnnotations, projectedAnnotations: projectedAnnotations)
    }

    private static func writeSQLiteIndex(at url: URL, rows: [Row], columns: [ColumnStat]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw ImportError.sqliteError("open failed")
        }
        defer { sqlite3_close_v2(db) }

        try exec("""
        CREATE TABLE alignment_rows (
            id TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            display_name TEXT NOT NULL,
            row_order INTEGER NOT NULL,
            aligned_length INTEGER NOT NULL,
            ungapped_length INTEGER NOT NULL,
            gap_count INTEGER NOT NULL,
            ambiguous_count INTEGER NOT NULL,
            checksum_sha256 TEXT NOT NULL
        );
        CREATE TABLE column_stats (
            column_index INTEGER PRIMARY KEY,
            consensus_residue TEXT NOT NULL,
            residue_counts_json TEXT NOT NULL,
            gap_fraction REAL NOT NULL,
            conservation REAL NOT NULL,
            entropy REAL NOT NULL,
            variable_site INTEGER NOT NULL,
            parsimony_informative INTEGER NOT NULL
        );
        """, db: db)

        try exec("BEGIN TRANSACTION", db: db)
        do {
            try rows.forEach { row in
                try execute(
                    "INSERT INTO alignment_rows VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    values: [
                        row.id,
                        row.sourceName,
                        row.displayName,
                        row.order,
                        row.alignedLength,
                        row.ungappedLength,
                        row.gapCount,
                        row.ambiguousCount,
                        row.checksumSHA256,
                    ],
                    db: db
                )
            }
            try columns.forEach { column in
                let countsData = try JSONSerialization.data(withJSONObject: column.residueCounts, options: [.sortedKeys])
                let countsJSON = String(data: countsData, encoding: .utf8) ?? "{}"
                try execute(
                    "INSERT INTO column_stats VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    values: [
                        column.index,
                        column.consensusResidue,
                        countsJSON,
                        column.gapFraction,
                        column.conservation,
                        column.entropy,
                        column.variableSite ? 1 : 0,
                        column.parsimonyInformative ? 1 : 0,
                    ],
                    db: db
                )
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw ImportError.sqliteError(message)
        }
    }

    private static func execute(_ sql: String, values: [Any], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case let int as Int:
                sqlite3_bind_int64(statement, position, Int64(int))
            case let double as Double:
                sqlite3_bind_double(statement, position, double)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ImportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.malformedInput("Could not encode annotation metadata as UTF-8 JSON.")
        }
        return text
    }

    private static func optionalJSONString<T: Encodable>(_ value: T?) throws -> Any {
        guard let value else { return NSNull() }
        return try jsonString(value)
    }

    private static func valueFromJSONString<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw ImportError.malformedInput("Could not decode annotation metadata JSON.")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func optionalValueFromJSONString<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T? {
        guard let text, !text.isEmpty else { return nil }
        return try valueFromJSONString(type, text)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private static func checksum(at url: URL) throws -> String {
        try sha256Hex(for: Data(contentsOf: url))
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func fileRecord(for url: URL) throws -> FileRecord {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return FileRecord(
                path: url.path,
                checksumSHA256: try directoryChecksum(at: url),
                fileSize: try directorySize(at: url)
            )
        }
        return FileRecord(path: url.path, checksumSHA256: try checksum(at: url), fileSize: try fileSize(at: url))
    }

    private static func directoryChecksum(at url: URL) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return sha256Hex(for: Data())
        }

        var entries: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(fileURL.path.dropFirst(url.path.count + 1))
            let digest = try checksum(at: fileURL)
            let size = try fileSize(at: fileURL)
            entries.append("\(relativePath)\t\(size)\t\(digest)")
        }
        entries.sort()
        return sha256Hex(for: Data(entries.joined(separator: "\n").utf8))
    }

    private static func fileRecords(bundleURL: URL, relativePaths: [String]) throws -> [String: FileRecord] {
        var result: [String: FileRecord] = [:]
        for relativePath in relativePaths {
            result[relativePath] = try fileRecord(for: bundleURL.appendingPathComponent(relativePath))
        }
        return result
    }

    private static func directorySize(at url: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return total
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func bundleDigest(checksums: [String: String]) -> String {
        let joined = checksums.keys.sorted()
            .map { "\($0)=\(checksums[$0] ?? "")" }
            .joined(separator: "\n")
        return sha256Hex(for: Data(joined.utf8))
    }

    private static func defaultArgv(inputURL: URL, bundleURL: URL, name: String) -> [String] {
        ["lungfish", "import", "msa", inputURL.path, "--output", bundleURL.path, "--name", name]
    }

    private static func shellCommand(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private static func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
