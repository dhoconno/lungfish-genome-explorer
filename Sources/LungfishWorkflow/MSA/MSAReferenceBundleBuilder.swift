import Foundation
import LungfishCore
import LungfishIO

public struct MSAReferenceSequenceInput: Sendable, Equatable {
    public let rowID: String
    public let rowName: String
    public let sourceName: String
    public let outputName: String
    public let alignedSequence: String
    public let alignedColumns: [Int]
    public let coordinateMap: MultipleSequenceAlignmentBundle.RowCoordinateMap

    public init(
        rowID: String,
        rowName: String,
        sourceName: String,
        outputName: String,
        alignedSequence: String,
        alignedColumns: [Int],
        coordinateMap: MultipleSequenceAlignmentBundle.RowCoordinateMap
    ) {
        self.rowID = rowID
        self.rowName = rowName
        self.sourceName = sourceName
        self.outputName = outputName
        self.alignedSequence = alignedSequence
        self.alignedColumns = alignedColumns
        self.coordinateMap = coordinateMap
    }
}

public struct MSAReferenceBundleBuildRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let sourceBundleName: String
    public let sourceBundleChecksumSHA256: String
    public let sourceBundleFileSize: Int64
    public let inputAlignmentFileURL: URL
    public let outputBundleURL: URL
    public let name: String
    public let rowsOption: String?
    public let columnsOption: String?
    public let selectedColumnIntervals: [MSAReferenceColumnInterval]
    public let sequences: [MSAReferenceSequenceInput]
    public let sourceAnnotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord]
    public let argv: [String]
    public let reproducibleCommand: String
    public let workflowName: String
    public let actionID: String
    public let toolName: String
    public let startedAt: Date
    public let force: Bool

    public init(
        sourceBundleURL: URL,
        sourceBundleName: String,
        sourceBundleChecksumSHA256: String,
        sourceBundleFileSize: Int64,
        inputAlignmentFileURL: URL,
        outputBundleURL: URL,
        name: String,
        rowsOption: String?,
        columnsOption: String?,
        selectedColumnIntervals: [MSAReferenceColumnInterval],
        sequences: [MSAReferenceSequenceInput],
        sourceAnnotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = [],
        argv: [String],
        reproducibleCommand: String,
        workflowName: String,
        actionID: String,
        toolName: String,
        startedAt: Date,
        force: Bool
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleName = sourceBundleName
        self.sourceBundleChecksumSHA256 = sourceBundleChecksumSHA256
        self.sourceBundleFileSize = sourceBundleFileSize
        self.inputAlignmentFileURL = inputAlignmentFileURL
        self.outputBundleURL = outputBundleURL
        self.name = name
        self.rowsOption = rowsOption
        self.columnsOption = columnsOption
        self.selectedColumnIntervals = selectedColumnIntervals
        self.sequences = sequences
        self.sourceAnnotations = sourceAnnotations
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.workflowName = workflowName
        self.actionID = actionID
        self.toolName = toolName
        self.startedAt = startedAt
        self.force = force
    }
}

public struct MSAReferenceColumnInterval: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct MSAReferenceBundleBuildResult: Sendable, Equatable {
    public let bundleURL: URL
    public let sequenceCount: Int
    public let totalLength: Int
    public let warnings: [String]

    public init(bundleURL: URL, sequenceCount: Int, totalLength: Int, warnings: [String]) {
        self.bundleURL = bundleURL
        self.sequenceCount = sequenceCount
        self.totalLength = totalLength
        self.warnings = warnings
    }
}

public struct MSAConsensusReferenceBundleBuildRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let sourceBundleName: String
    public let sourceBundleChecksumSHA256: String
    public let sourceBundleFileSize: Int64
    public let inputAlignmentFileURL: URL
    public let outputBundleURL: URL
    public let name: String
    public let consensusSequence: String
    public let alignmentColumns: [Int]
    public let rowsOption: String?
    public let threshold: Double
    public let gapPolicy: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let workflowName: String
    public let actionID: String
    public let toolName: String
    public let startedAt: Date
    public let force: Bool

    public init(
        sourceBundleURL: URL,
        sourceBundleName: String,
        sourceBundleChecksumSHA256: String,
        sourceBundleFileSize: Int64,
        inputAlignmentFileURL: URL,
        outputBundleURL: URL,
        name: String,
        consensusSequence: String,
        alignmentColumns: [Int],
        rowsOption: String?,
        threshold: Double,
        gapPolicy: String,
        argv: [String],
        reproducibleCommand: String,
        workflowName: String,
        actionID: String,
        toolName: String,
        startedAt: Date,
        force: Bool
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleName = sourceBundleName
        self.sourceBundleChecksumSHA256 = sourceBundleChecksumSHA256
        self.sourceBundleFileSize = sourceBundleFileSize
        self.inputAlignmentFileURL = inputAlignmentFileURL
        self.outputBundleURL = outputBundleURL
        self.name = name
        self.consensusSequence = consensusSequence
        self.alignmentColumns = alignmentColumns
        self.rowsOption = rowsOption
        self.threshold = threshold
        self.gapPolicy = gapPolicy
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.workflowName = workflowName
        self.actionID = actionID
        self.toolName = toolName
        self.startedAt = startedAt
        self.force = force
    }
}

public enum MSAReferenceBundleBuilderError: Error, LocalizedError, Equatable {
    case emptySelection
    case outputExists(URL)
    case unsupportedResidue(sequence: String, residue: Character)
    case missingCoordinate(sequence: String, alignmentColumn: Int)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "MSA reference extraction produced no ungapped nucleotide sequences."
        case .outputExists(let url):
            return "Output bundle already exists: \(url.path)"
        case .unsupportedResidue(let sequence, let residue):
            return "MSA reference extraction only supports nucleotide sequences; \(sequence) contains unsupported residue '\(residue)'."
        case .missingCoordinate(let sequence, let alignmentColumn):
            return "MSA coordinate map for \(sequence) does not map alignment column \(alignmentColumn + 1) to an ungapped source coordinate."
        }
    }
}

public enum MSAReferenceBundleBuilder {
    public static func build(
        request: MSAReferenceBundleBuildRequest
    ) throws -> MSAReferenceBundleBuildResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: request.outputBundleURL.path) {
            guard request.force else {
                throw MSAReferenceBundleBuilderError.outputExists(request.outputBundleURL)
            }
            try fm.removeItem(at: request.outputBundleURL)
        }

        let transformed = try transformSequences(request.sequences)
        guard transformed.isEmpty == false else {
            throw MSAReferenceBundleBuilderError.emptySelection
        }

        try fm.createDirectory(at: request.outputBundleURL, withIntermediateDirectories: true)
        let genomeDirectory = request.outputBundleURL.appendingPathComponent("genome", isDirectory: true)
        let metadataDirectory = request.outputBundleURL.appendingPathComponent("metadata", isDirectory: true)
        let annotationsDirectory = request.outputBundleURL.appendingPathComponent("annotations", isDirectory: true)
        try fm.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)

        let fastaURL = genomeDirectory.appendingPathComponent("sequence.fa")
        try writeFASTA(transformed, to: fastaURL)
        let fastaIndex = try FASTAIndexBuilder.build(for: fastaURL)
        let fastaIndexURL = fastaURL.appendingPathExtension("fai")
        try fastaIndex.write(to: fastaIndexURL)

        let chromosomes = fastaIndex.sequenceNames.compactMap { name -> ChromosomeInfo? in
            guard let entry = fastaIndex.entry(for: name) else { return nil }
            return ChromosomeInfo(
                name: entry.name,
                length: Int64(entry.length),
                offset: Int64(entry.offset),
                lineBases: entry.lineBases,
                lineWidth: entry.lineWidth
            )
        }
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }
        let liftedAnnotationTrack = try writeLiftedAnnotationTrack(
            sourceAnnotations: request.sourceAnnotations,
            transformedSequences: transformed,
            annotationsDirectory: annotationsDirectory
        )
        let manifest = BundleManifest(
            name: request.name,
            identifier: "org.lungfish.msa.reference.\(UUID().uuidString.lowercased())",
            description: "Reference sequences extracted from a multiple sequence alignment.",
            source: SourceInfo(
                organism: "Multiple sequence alignment extraction",
                assembly: request.name,
                database: "Lungfish MSA",
                sourceURL: request.sourceBundleURL,
                notes: "Derived from \(request.sourceBundleName). Alignment gaps were omitted from reference sequences."
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                gzipIndexPath: nil,
                totalLength: totalLength,
                chromosomes: chromosomes
            ),
            annotations: liftedAnnotationTrack.map { [$0.track] } ?? [],
            metadata: [
                MetadataGroup(
                    name: "MSA Selection",
                    items: [
                        MetadataItem(label: "Source Alignment", value: request.sourceBundleName),
                        MetadataItem(label: "Rows", value: request.rowsOption ?? "all"),
                        MetadataItem(label: "Columns", value: request.columnsOption ?? "all"),
                        MetadataItem(label: "Output Kind", value: "reference"),
                    ]
                ),
            ]
        )
        try manifest.save(to: request.outputBundleURL)

        let selectionMetadata = MSAReferenceSelectionMetadata(
            sourceBundlePath: request.sourceBundleURL.path,
            sourceBundleName: request.sourceBundleName,
            rows: request.rowsOption,
            columns: request.columnsOption,
            selectedRowCount: transformed.count,
            selectedColumnCount: request.sequences.first?.alignedColumns.count ?? 0,
            selectedAlignedIntervals: request.selectedColumnIntervals,
            gapPolicy: "omit",
            coordinateSystem: "0-based half-open intervals; per-base arrays use 0-based coordinates"
        )
        try writeJSON(selectionMetadata, to: metadataDirectory.appendingPathComponent("msa-selection.json"))

        let coordinateMetadata = MSAReferenceCoordinateMapMetadata(
            sourceBundlePath: request.sourceBundleURL.path,
            sourceBundleName: request.sourceBundleName,
            coordinateSystem: "0-based",
            rows: transformed.map(\.coordinateMap)
        )
        try writeJSON(coordinateMetadata, to: metadataDirectory.appendingPathComponent("msa-coordinate-map.json"))

        let metadataFiles = try [
            "metadata/msa-selection.json",
            "metadata/msa-coordinate-map.json",
        ].map { try fileRecord(at: request.outputBundleURL.appendingPathComponent($0), relativePath: $0) }
        var outputRelativePaths = [
            "manifest.json",
            "genome/sequence.fa",
            "genome/sequence.fa.fai",
        ]
        if liftedAnnotationTrack != nil {
            outputRelativePaths.append("annotations/msa_lifted_annotations.db")
        }
        let outputFiles = try outputRelativePaths
            .map { try fileRecord(at: request.outputBundleURL.appendingPathComponent($0), relativePath: $0) }
        let outputBundle = try bundleRecord(at: request.outputBundleURL)

        let provenance = try MSAReferenceBundleProvenance(
            workflowName: request.workflowName,
            actionID: request.actionID,
            toolName: request.toolName,
            toolVersion: MultipleSequenceAlignmentBundle.toolVersion,
            argv: request.argv,
            reproducibleCommand: request.reproducibleCommand,
            runtime: .current(),
            inputBundle: .init(
                path: request.sourceBundleURL.path,
                checksumSHA256: request.sourceBundleChecksumSHA256,
                fileSize: request.sourceBundleFileSize
            ),
            inputAlignmentFile: fileRecord(at: request.inputAlignmentFileURL),
            outputBundle: outputBundle,
            outputBundlePath: request.outputBundleURL.path,
            outputFiles: outputFiles,
            metadataFiles: metadataFiles,
            options: .init(
                outputKind: "reference",
                rows: request.rowsOption,
                columns: request.columnsOption,
                selectedRowCount: transformed.count,
                selectedColumnCount: request.sequences.first?.alignedColumns.count ?? 0,
                outputSequenceCount: transformed.count,
                outputTotalLength: Int(totalLength),
                name: request.name,
                propagatedAnnotationCount: liftedAnnotationTrack?.featureCount,
                threshold: nil,
                gapPolicy: "omit"
            ),
            exitStatus: 0,
            wallTimeSeconds: max(0, Date().timeIntervalSince(request.startedAt)),
            warnings: []
        )
        try writeJSON(provenance, to: request.outputBundleURL.appendingPathComponent(".lungfish-provenance.json"))

        return MSAReferenceBundleBuildResult(
            bundleURL: request.outputBundleURL,
            sequenceCount: transformed.count,
            totalLength: Int(totalLength),
            warnings: []
        )
    }

    public static func buildConsensus(
        request: MSAConsensusReferenceBundleBuildRequest
    ) throws -> MSAReferenceBundleBuildResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: request.outputBundleURL.path) {
            guard request.force else {
                throw MSAReferenceBundleBuilderError.outputExists(request.outputBundleURL)
            }
            try fm.removeItem(at: request.outputBundleURL)
        }

        let transformed = try transformConsensus(
            sequenceName: request.name,
            sequence: request.consensusSequence,
            alignmentColumns: request.alignmentColumns
        )
        guard transformed.sequence.isEmpty == false else {
            throw MSAReferenceBundleBuilderError.emptySelection
        }

        try fm.createDirectory(at: request.outputBundleURL, withIntermediateDirectories: true)
        let genomeDirectory = request.outputBundleURL.appendingPathComponent("genome", isDirectory: true)
        let metadataDirectory = request.outputBundleURL.appendingPathComponent("metadata", isDirectory: true)
        try fm.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        let fastaURL = genomeDirectory.appendingPathComponent("sequence.fa")
        try writeFASTA([transformed], to: fastaURL)
        let fastaIndex = try FASTAIndexBuilder.build(for: fastaURL)
        let fastaIndexURL = fastaURL.appendingPathExtension("fai")
        try fastaIndex.write(to: fastaIndexURL)
        let chromosomes = fastaIndex.sequenceNames.compactMap { name -> ChromosomeInfo? in
            guard let entry = fastaIndex.entry(for: name) else { return nil }
            return ChromosomeInfo(
                name: entry.name,
                length: Int64(entry.length),
                offset: Int64(entry.offset),
                lineBases: entry.lineBases,
                lineWidth: entry.lineWidth
            )
        }
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }
        let manifest = BundleManifest(
            name: request.name,
            identifier: "org.lungfish.msa.consensus-reference.\(UUID().uuidString.lowercased())",
            description: "Consensus reference sequence derived from a multiple sequence alignment.",
            source: SourceInfo(
                organism: "Multiple sequence alignment consensus",
                assembly: request.name,
                database: "Lungfish MSA",
                sourceURL: request.sourceBundleURL,
                notes: "Consensus derived from \(request.sourceBundleName). Alignment gaps were omitted from the reference sequence."
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                gzipIndexPath: nil,
                totalLength: totalLength,
                chromosomes: chromosomes
            ),
            metadata: [
                MetadataGroup(
                    name: "MSA Consensus",
                    items: [
                        MetadataItem(label: "Source Alignment", value: request.sourceBundleName),
                        MetadataItem(label: "Rows", value: request.rowsOption ?? "all"),
                        MetadataItem(label: "Threshold", value: String(request.threshold)),
                        MetadataItem(label: "Gap Policy", value: request.gapPolicy),
                        MetadataItem(label: "Output Kind", value: "reference"),
                    ]
                ),
            ]
        )
        try manifest.save(to: request.outputBundleURL)

        let consensusMetadata = MSAConsensusReferenceMetadata(
            sourceBundlePath: request.sourceBundleURL.path,
            sourceBundleName: request.sourceBundleName,
            rows: request.rowsOption,
            threshold: request.threshold,
            gapPolicy: request.gapPolicy,
            outputSequenceName: request.name,
            outputLength: transformed.sequence.count,
            alignmentColumns: transformed.coordinateMap.alignmentColumns,
            coordinateSystem: "0-based"
        )
        try writeJSON(consensusMetadata, to: metadataDirectory.appendingPathComponent("msa-consensus.json"))

        let metadataFiles = try [
            "metadata/msa-consensus.json",
        ].map { try fileRecord(at: request.outputBundleURL.appendingPathComponent($0), relativePath: $0) }
        let outputFiles = try [
            "manifest.json",
            "genome/sequence.fa",
            "genome/sequence.fa.fai",
        ].map { try fileRecord(at: request.outputBundleURL.appendingPathComponent($0), relativePath: $0) }
        let outputBundle = try bundleRecord(at: request.outputBundleURL)
        let provenance = try MSAReferenceBundleProvenance(
            workflowName: request.workflowName,
            actionID: request.actionID,
            toolName: request.toolName,
            toolVersion: MultipleSequenceAlignmentBundle.toolVersion,
            argv: request.argv,
            reproducibleCommand: request.reproducibleCommand,
            runtime: .current(),
            inputBundle: .init(
                path: request.sourceBundleURL.path,
                checksumSHA256: request.sourceBundleChecksumSHA256,
                fileSize: request.sourceBundleFileSize
            ),
            inputAlignmentFile: fileRecord(at: request.inputAlignmentFileURL),
            outputBundle: outputBundle,
            outputBundlePath: request.outputBundleURL.path,
            outputFiles: outputFiles,
            metadataFiles: metadataFiles,
            options: .init(
                outputKind: "reference",
                rows: request.rowsOption,
                columns: nil,
                selectedRowCount: nil,
                selectedColumnCount: request.consensusSequence.count,
                outputSequenceCount: 1,
                outputTotalLength: Int(totalLength),
                name: request.name,
                propagatedAnnotationCount: nil,
                threshold: request.threshold,
                gapPolicy: request.gapPolicy
            ),
            exitStatus: 0,
            wallTimeSeconds: max(0, Date().timeIntervalSince(request.startedAt)),
            warnings: []
        )
        try writeJSON(provenance, to: request.outputBundleURL.appendingPathComponent(".lungfish-provenance.json"))

        return MSAReferenceBundleBuildResult(
            bundleURL: request.outputBundleURL,
            sequenceCount: 1,
            totalLength: Int(totalLength),
            warnings: []
        )
    }

    private static func transformSequences(
        _ sequences: [MSAReferenceSequenceInput]
    ) throws -> [TransformedSequence] {
        try sequences.compactMap { input in
            var ungapped = ""
            var outputCoordinates: [Int] = []
            var alignmentColumns: [Int] = []
            var sourceCoordinates: [Int] = []

            let residues = Array(input.alignedSequence)
            for (offset, residue) in residues.enumerated() {
                guard input.alignedColumns.indices.contains(offset) else { continue }
                let alignedColumn = input.alignedColumns[offset]
                if isGap(residue) {
                    continue
                }
                guard isSupportedNucleotide(residue) else {
                    throw MSAReferenceBundleBuilderError.unsupportedResidue(
                        sequence: input.outputName,
                        residue: residue
                    )
                }
                guard input.coordinateMap.alignmentToUngapped.indices.contains(alignedColumn),
                      let sourceCoordinate = input.coordinateMap.alignmentToUngapped[alignedColumn] else {
                    throw MSAReferenceBundleBuilderError.missingCoordinate(
                        sequence: input.outputName,
                        alignmentColumn: alignedColumn
                    )
                }
                outputCoordinates.append(ungapped.count)
                alignmentColumns.append(alignedColumn)
                sourceCoordinates.append(sourceCoordinate)
                ungapped.append(residue)
            }

            guard ungapped.isEmpty == false else { return nil }
            return TransformedSequence(
                name: input.outputName,
                sequence: ungapped,
                coordinateMap: MSAReferenceRowCoordinateMapMetadata(
                    rowID: input.rowID,
                    rowName: input.rowName,
                    sourceSequenceName: input.sourceName,
                    outputSequenceName: input.outputName,
                    outputLength: ungapped.count,
                    outputCoordinates: outputCoordinates,
                    alignmentColumns: alignmentColumns,
                    sourceUngappedCoordinates: sourceCoordinates
                )
            )
        }
    }

    private static func transformConsensus(
        sequenceName: String,
        sequence: String,
        alignmentColumns: [Int]
    ) throws -> TransformedSequence {
        var ungapped = ""
        var outputCoordinates: [Int] = []
        var retainedAlignmentColumns: [Int] = []
        let residues = Array(sequence)
        for (offset, residue) in residues.enumerated() {
            guard alignmentColumns.indices.contains(offset) else { continue }
            if isGap(residue) {
                continue
            }
            guard isSupportedNucleotide(residue) else {
                throw MSAReferenceBundleBuilderError.unsupportedResidue(sequence: sequenceName, residue: residue)
            }
            outputCoordinates.append(ungapped.count)
            retainedAlignmentColumns.append(alignmentColumns[offset])
            ungapped.append(residue)
        }
        return TransformedSequence(
            name: sequenceName,
            sequence: ungapped,
            coordinateMap: MSAReferenceRowCoordinateMapMetadata(
                rowID: "consensus",
                rowName: sequenceName,
                sourceSequenceName: "MSA consensus",
                outputSequenceName: sequenceName,
                outputLength: ungapped.count,
                outputCoordinates: outputCoordinates,
                alignmentColumns: retainedAlignmentColumns,
                sourceUngappedCoordinates: []
            )
        )
    }

    private static func writeLiftedAnnotationTrack(
        sourceAnnotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord],
        transformedSequences: [TransformedSequence],
        annotationsDirectory: URL
    ) throws -> (track: AnnotationTrackInfo, featureCount: Int)? {
        guard sourceAnnotations.isEmpty == false else { return nil }

        var bedLines: [String] = []
        for sequence in transformedSequences {
            let outputByAlignmentColumn = Dictionary(
                uniqueKeysWithValues: zip(sequence.coordinateMap.alignmentColumns, sequence.coordinateMap.outputCoordinates)
            )
            for annotation in sourceAnnotations where annotation.rowID == sequence.coordinateMap.rowID {
                let outputIntervals = collapseCoordinates(
                    annotation.alignedIntervals.flatMap { interval in
                        guard interval.start < interval.end else { return [Int]() }
                        return (interval.start..<interval.end).compactMap { outputByAlignmentColumn[$0] }
                    }
                )
                guard outputIntervals.isEmpty == false else { continue }
                bedLines.append(bedLine(
                    annotation: annotation,
                    chromosome: sequence.name,
                    intervals: outputIntervals
                ))
            }
        }
        guard bedLines.isEmpty == false else { return nil }

        let bedURL = annotationsDirectory.appendingPathComponent("msa_lifted_annotations.seed.bed")
        let dbURL = annotationsDirectory.appendingPathComponent("msa_lifted_annotations.db")
        try bedLines.joined().write(to: bedURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bedURL) }
        let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let track = AnnotationTrackInfo(
            id: "msa_lifted_annotations",
            name: "MSA Lifted Annotations",
            description: "Annotations propagated from aligned MSA rows into extracted reference coordinates.",
            path: "annotations/msa_lifted_annotations.db",
            databasePath: "annotations/msa_lifted_annotations.db",
            annotationType: .custom,
            featureCount: featureCount,
            source: "Lungfish MSA annotation lift-over",
            version: "lungfish-cli"
        )
        return (track, featureCount)
    }

    private static func bedLine(
        annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord,
        chromosome: String,
        intervals: [AnnotationInterval]
    ) -> String {
        let start = intervals.map(\.start).min() ?? 0
        let end = intervals.map(\.end).max() ?? start
        let blockSizes = intervals.map { "\($0.end - $0.start)" }.joined(separator: ",") + ","
        let blockStarts = intervals.map { "\($0.start - start)" }.joined(separator: ",") + ","
        return [
            chromosome,
            String(start),
            String(end),
            bedField(annotation.name),
            "0",
            annotation.strand,
            String(start),
            String(end),
            "0,0,0",
            String(intervals.count),
            blockSizes,
            blockStarts,
            annotation.type,
            attributes(for: annotation),
        ].joined(separator: "\t") + "\n"
    }

    private static func collapseCoordinates(_ coordinates: [Int]) -> [AnnotationInterval] {
        let sorted = Array(Set(coordinates)).sorted()
        guard var start = sorted.first else { return [] }
        var previous = start
        var intervals: [AnnotationInterval] = []
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

    private static func attributes(
        for annotation: MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord
    ) -> String {
        var pairs: [(String, String)] = [
            ("source_msa_annotation_id", annotation.id),
            ("source_msa_row_id", annotation.rowID),
            ("source_msa_row_name", annotation.rowName),
            ("source_msa_origin", annotation.origin.rawValue),
        ]
        if let note = annotation.note, note.isEmpty == false {
            pairs.append(("Note", note))
        }
        for (key, values) in annotation.qualifiers.sorted(by: { $0.key < $1.key }) {
            pairs.append((key, values.joined(separator: ",")))
        }
        return pairs
            .map { "\(bedAttributeField($0.0))=\(bedAttributeField($0.1))" }
            .joined(separator: ";")
    }

    private static func bedField(_ value: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MSA Annotation" : trimmed
    }

    private static func bedAttributeField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ";", with: "%3B")
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "\t", with: "%09")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func writeFASTA(_ sequences: [TransformedSequence], to url: URL) throws {
        let text = sequences.map { sequence in
            ">\(sequence.name)\n\(wrapped(sequence.sequence))"
        }
        .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func wrapped(_ sequence: String, lineLength: Int = 80) -> String {
        guard sequence.count > lineLength else { return sequence }
        var lines: [String] = []
        var current = ""
        current.reserveCapacity(lineLength)
        for character in sequence {
            current.append(character)
            if current.count == lineLength {
                lines.append(current)
                current = ""
            }
        }
        if current.isEmpty == false {
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }

    private static func isGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }

    private static func isSupportedNucleotide(_ residue: Character) -> Bool {
        let allowed = CharacterSet(charactersIn: "ACGTURYSWKMBDHVNacgturyswkmbdhvn?")
        return String(residue).unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func fileRecord(
        at url: URL,
        relativePath: String? = nil
    ) throws -> MSAReferenceBundleProvenance.FileRecord {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        return MSAReferenceBundleProvenance.FileRecord(
            path: url.path,
            relativePath: relativePath,
            checksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: data),
            fileSize: size
        )
    }

    private static func bundleRecord(at url: URL) throws -> MSAReferenceBundleProvenance.BundleRecord {
        MSAReferenceBundleProvenance.BundleRecord(
            path: url.path,
            checksumSHA256: try directoryChecksum(at: url),
            fileSize: try directorySize(at: url)
        )
    }

    private static func directoryChecksum(at url: URL) throws -> String {
        let entries = try visibleDirectoryFileRecords(at: url)
            .map { "\($0.relativePath)\t\($0.fileSize)\t\($0.checksum)" }
            .sorted()
            .joined(separator: "\n")
        return MultipleSequenceAlignmentBundle.sha256Hex(for: Data(entries.utf8))
    }

    private static func directorySize(at url: URL) throws -> Int64 {
        try visibleDirectoryFileRecords(at: url).reduce(Int64(0)) { $0 + $1.fileSize }
    }

    private static func visibleDirectoryFileRecords(
        at url: URL
    ) throws -> [(relativePath: String, fileSize: Int64, checksum: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [(relativePath: String, fileSize: Int64, checksum: String)] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(fileURL.path.dropFirst(url.path.count + 1))
            let data = try Data(contentsOf: fileURL)
            records.append((
                relativePath: relativePath,
                fileSize: Int64(values.fileSize ?? data.count),
                checksum: MultipleSequenceAlignmentBundle.sha256Hex(for: data)
            ))
        }
        return records
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

private struct TransformedSequence {
    let name: String
    let sequence: String
    let coordinateMap: MSAReferenceRowCoordinateMapMetadata
}

private struct MSAReferenceSelectionMetadata: Codable, Equatable {
    let sourceBundlePath: String
    let sourceBundleName: String
    let rows: String?
    let columns: String?
    let selectedRowCount: Int
    let selectedColumnCount: Int
    let selectedAlignedIntervals: [MSAReferenceColumnInterval]
    let gapPolicy: String
    let coordinateSystem: String
}

private struct MSAReferenceCoordinateMapMetadata: Codable, Equatable {
    let sourceBundlePath: String
    let sourceBundleName: String
    let coordinateSystem: String
    let rows: [MSAReferenceRowCoordinateMapMetadata]
}

private struct MSAConsensusReferenceMetadata: Codable, Equatable {
    let sourceBundlePath: String
    let sourceBundleName: String
    let rows: String?
    let threshold: Double
    let gapPolicy: String
    let outputSequenceName: String
    let outputLength: Int
    let alignmentColumns: [Int]
    let coordinateSystem: String
}

private struct MSAReferenceRowCoordinateMapMetadata: Codable, Equatable {
    let rowID: String
    let rowName: String
    let sourceSequenceName: String
    let outputSequenceName: String
    let outputLength: Int
    let outputCoordinates: [Int]
    let alignmentColumns: [Int]
    let sourceUngappedCoordinates: [Int]
}

private struct MSAReferenceBundleProvenance: Codable, Equatable {
    struct RuntimeIdentity: Codable, Equatable {
        let executablePath: String?
        let operatingSystemVersion: String
        let processIdentifier: Int32
        let condaEnvironment: String?
        let containerImage: String?

        static func current() -> RuntimeIdentity {
            RuntimeIdentity(
                executablePath: CommandLine.arguments.first,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                condaEnvironment: ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"],
                containerImage: ProcessInfo.processInfo.environment["LUNGFISH_CONTAINER_IMAGE"]
            )
        }
    }

    struct BundleRecord: Codable, Equatable {
        let path: String
        let checksumSHA256: String
        let fileSize: Int64
    }

    struct FileRecord: Codable, Equatable {
        let path: String
        let relativePath: String?
        let checksumSHA256: String
        let fileSize: Int64
    }

    struct Options: Codable, Equatable {
        let outputKind: String
        let rows: String?
        let columns: String?
        let selectedRowCount: Int?
        let selectedColumnCount: Int
        let outputSequenceCount: Int
        let outputTotalLength: Int
        let name: String
        let propagatedAnnotationCount: Int?
        let threshold: Double?
        let gapPolicy: String
    }

    let workflowName: String
    let actionID: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let reproducibleCommand: String
    let runtime: RuntimeIdentity
    let inputBundle: BundleRecord
    let inputAlignmentFile: FileRecord
    let outputBundle: BundleRecord
    let outputBundlePath: String
    let outputFiles: [FileRecord]
    let metadataFiles: [FileRecord]
    let options: Options
    let exitStatus: Int
    let wallTimeSeconds: Double
    let warnings: [String]
}
