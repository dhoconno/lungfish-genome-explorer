// SequenceExtractionPipeline.swift - Background bundle creation from extracted sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let extractionLogger = Logger(subsystem: LogSubsystem.app, category: "SequenceExtraction")

/// Builds a `.lungfishref` bundle from an extracted sequence.
///
/// This class is `@unchecked Sendable` (not `@MainActor`) so it can run
/// from `Task.detached` contexts. Progress is reported via `DownloadCenter`
/// singleton, following the same pattern as `GenBankBundleDownloadViewModel`.
public final class SequenceExtractionPipeline: @unchecked Sendable {

    public struct SourceAnnotationTrack: Sendable {
        public let id: String
        public let name: String
        public let databaseURL: URL
        public let annotationType: AnnotationTrackType

        public init(id: String, name: String, databaseURL: URL, annotationType: AnnotationTrackType) {
            self.id = id
            self.name = name
            self.databaseURL = databaseURL
            self.annotationType = annotationType
        }
    }

    public struct SourceVariantTrack: Sendable {
        public let id: String
        public let name: String
        public let databaseURL: URL
        public let variantType: VariantTrackType

        public init(id: String, name: String, databaseURL: URL, variantType: VariantTrackType) {
            self.id = id
            self.name = name
            self.databaseURL = databaseURL
            self.variantType = variantType
        }
    }

    private let toolRunner: NativeToolRunner

    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    /// Creates a `.lungfishref` bundle from an extraction result.
    ///
    /// Pipeline: write temp FASTA -> bgzip -> samtools faidx -> write manifest -> return bundle URL.
    ///
    /// - Parameters:
    ///   - result: The extraction result containing the nucleotide sequence.
    ///   - outputDirectory: Where to create the bundle.
    ///   - sourceBundle: Optional source bundle for metadata inheritance.
    ///   - progressHandler: Optional progress callback (fraction, message).
    /// - Returns: URL of the created `.lungfishref` bundle.
    public func buildBundle(
        from result: LungfishCore.ExtractionResult,
        outputDirectory: URL,
        sourceBundleURL: URL? = nil,
        sourceBundleName: String? = nil,
        desiredBundleName: String? = nil,
        sourceBundleChromosomes: [ChromosomeInfo] = [],
        sourceAnnotationTracks: [SourceAnnotationTrack] = [],
        sourceVariantTracks: [SourceVariantTrack] = [],
        sampleFilter: Set<String>? = nil,
        isConcatenated: Bool = false,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        let startedAt = Date()

        if sourceAnnotationTracks.isEmpty,
           sourceVariantTracks.isEmpty,
           sampleFilter == nil,
           !isConcatenated {
            let bundleBaseName: String
            if let desiredBundleName, !desiredBundleName.isEmpty {
                bundleBaseName = BundleBuildHelpers.sanitizedFilename(desiredBundleName)
            } else {
                let seqName = BundleBuildHelpers.sanitizedFilename(result.sourceName)
                bundleBaseName = seqName.isEmpty ? "extracted_sequence" : seqName
            }
            let outputBundleURL = BundleBuildHelpers.makeUniqueBundleURL(
                baseName: bundleBaseName,
                in: outputDirectory
            )
            let argv = Self.extractionProvenanceArguments(
                result: result,
                bundleURL: outputBundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            )
            let context = SequenceExtractionBundleCommandContext(
                workflowName: "lungfish gui sequence extraction",
                toolName: "lungfish gui sequence extraction",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                explicitOptions: Self.extractionExplicitOptions(
                    result: result,
                    sourceBundleURL: sourceBundleURL,
                    sourceBundleName: sourceBundleName,
                    desiredBundleName: desiredBundleName,
                    sampleFilter: sampleFilter,
                    isConcatenated: isConcatenated
                ),
                defaultOptions: [
                    "reverse_complement": .boolean(false),
                    "concatenate_exons": .boolean(false),
                    "sample_filter": .array([]),
                ],
                resolvedOptions: Self.extractionResolvedOptions(
                    result: result,
                    bundleURL: outputBundleURL,
                    sourceBundleURL: sourceBundleURL,
                    sourceBundleName: sourceBundleName,
                    desiredBundleName: desiredBundleName,
                    sampleFilter: sampleFilter,
                    isConcatenated: isConcatenated
                ),
                inputURLs: []
            )
            return try await SequenceExtractionBundleBuilder().buildBundle(
                request: SequenceExtractionBundleBuildRequest(
                    result: result,
                    outputDirectory: outputDirectory,
                    outputBundleURL: outputBundleURL,
                    sourceBundleURL: sourceBundleURL,
                    sourceBundleName: sourceBundleName,
                    desiredBundleName: desiredBundleName,
                    commandContext: context
                ),
                progressHandler: progressHandler
            )
        }

        progressHandler?(0.05, "Checking tools...")
        try await BundleBuildHelpers.validateTools(using: toolRunner)

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "extract-", contextURL: outputDirectory)
        // Cleanup is best-effort and asynchronous to avoid blocking return after
        // bundle creation on platforms where temp dir removal can stall.
        defer {
            let cleanupURL = tempDir
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        // Write plain FASTA
        progressHandler?(0.15, "Writing FASTA...")
        let seqName = BundleBuildHelpers.sanitizedFilename(result.sourceName)
        let plainFASTA = tempDir.appendingPathComponent("sequence.fa")
        let fastaContent = SequenceExtractor.formatFASTA(result)
        try fastaContent.write(to: plainFASTA, atomically: true, encoding: .utf8)

        // Bgzip compress
        progressHandler?(0.30, "Compressing (bgzip)...")
        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }
        let compressedFASTA = tempDir.appendingPathComponent("sequence.fa.gz")

        // Index FASTA
        progressHandler?(0.50, "Indexing (samtools faidx)...")
        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")

        // Parse chromosome info from fai
        let chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        // Create bundle directory structure
        progressHandler?(0.70, "Creating bundle...")
        let bundleName: String
        if let desired = desiredBundleName, !desired.isEmpty {
            bundleName = BundleBuildHelpers.sanitizedFilename(desired)
        } else {
            bundleName = seqName.isEmpty ? "extracted_sequence" : seqName
        }
        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(
            baseName: bundleName,
            in: outputDirectory
        )
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        // Move files into bundle
        let bundleFASTAURL = genomeDir.appendingPathComponent("sequence.fa.gz")
        let bundleFAIURL = genomeDir.appendingPathComponent("sequence.fa.gz.fai")
        let bundleGZIURL = genomeDir.appendingPathComponent("sequence.fa.gz.gzi")
        try fileManager.moveItem(at: compressedFASTA, to: bundleFASTAURL)
        try fileManager.moveItem(at: faiURL, to: bundleFAIURL)
        let hasGzi = fileManager.fileExists(atPath: gziURL.path)
        if hasGzi {
            try fileManager.moveItem(at: gziURL, to: bundleGZIURL)
        }
        var provenanceOutputURLs = [bundleFASTAURL, bundleFAIURL]
        if hasGzi {
            provenanceOutputURLs.append(bundleGZIURL)
        }

        // Extract annotations from source bundle
        var annotationTracks: [AnnotationTrackInfo] = []
        if !isConcatenated, !sourceAnnotationTracks.isEmpty {
            progressHandler?(0.78, "Extracting annotations...")
            let newChromName = chromosomes.first?.name ?? seqName
            let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
            try fileManager.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

            for (trackIndex, sourceTrack) in sourceAnnotationTracks.enumerated() {
                do {
                    let sourceDB = try AnnotationDatabase(url: sourceTrack.databaseURL)
                    let queryChromosomes = Self.annotationChromosomeCandidates(
                        sourceChromosome: result.chromosome,
                        sourceBundleChromosomes: sourceBundleChromosomes,
                        annotationChromosomes: sourceDB.allChromosomes()
                    )
                    var sourceRecords: [AnnotationDatabaseRecord] = []
                    var seenAnnotationKeys = Set<String>()
                    for queryChromosome in queryChromosomes {
                        // Use a large cap for extraction paths so full-region content is preserved.
                        let records = sourceDB.queryByRegion(
                            chromosome: queryChromosome,
                            start: result.effectiveStart,
                            end: result.effectiveEnd,
                            limit: 1_000_000
                        )
                        for record in records {
                            let key = "\(record.name)|\(record.type)|\(record.chromosome)|\(record.start)|\(record.end)|\(record.strand)"
                            guard seenAnnotationKeys.insert(key).inserted else { continue }
                            sourceRecords.append(record)
                        }
                    }

                    let transformed = sourceRecords.compactMap { record -> AnnotationDatabaseRecord? in
                        // Skip "region" annotations that span the entire extraction —
                        // they represent chromosome/contig boundaries and are meaningless
                        // in extracted sub-sequences.
                        if record.type == "region" {
                            let span = record.end - record.start
                            let extractionSpan = result.effectiveEnd - result.effectiveStart
                            if span >= Int(Double(extractionSpan) * 0.90) {
                                return nil
                            }
                        }
                        return record.transformed(
                            extractionStart: result.effectiveStart,
                            extractionEnd: result.effectiveEnd,
                            isReverseComplement: result.isReverseComplement,
                            newChromosome: newChromName
                        )
                    }

                    guard !transformed.isEmpty else { continue }

                    let sanitizedTrackID = BundleBuildHelpers.sanitizedFilename(sourceTrack.id)
                    let trackID = sanitizedTrackID.isEmpty ? UUID().uuidString : sanitizedTrackID
                    let dbFilename = "annotations_\(trackIndex)_\(trackID).db"

                    let bedURL = tempDir.appendingPathComponent("\(dbFilename).bed")
                    let bedContent = transformed.map { $0.toBED12PlusLine() }.joined(separator: "\n")
                    try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

                    let dbURL = annotationsDir.appendingPathComponent(dbFilename)
                    let dbRecordCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
                    guard dbRecordCount > 0 else { continue }
                    provenanceOutputURLs.append(dbURL)

                    let relativePath = "annotations/\(dbFilename)"
                    annotationTracks.append(AnnotationTrackInfo(
                        id: sourceTrack.id,
                        name: sourceTrack.name,
                        description: "Coordinate-transformed annotations from source bundle track '\(sourceTrack.name)'",
                        path: relativePath,
                        databasePath: relativePath,
                        annotationType: sourceTrack.annotationType,
                        featureCount: dbRecordCount
                    ))
                    extractionLogger.info("buildBundle: Extracted \(dbRecordCount) annotations for track \(sourceTrack.id)")
                } catch {
                    extractionLogger.warning("buildBundle: Annotation extraction failed for track \(sourceTrack.id, privacy: .public) (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Extract variants from source bundle
        var variantTracks: [VariantTrackInfo] = []
        if !isConcatenated, !sourceVariantTracks.isEmpty {
            progressHandler?(0.82, "Extracting variants...")
            let newChromName = chromosomes.first?.name ?? seqName
            let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
            try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

            for (trackIndex, sourceTrack) in sourceVariantTracks.enumerated() {
                do {
                    let sourceDB = try VariantDatabase(url: sourceTrack.databaseURL)
                    let chromosomeAliases = Self.variantChromosomeAliases(
                        sourceChromosome: result.chromosome,
                        sourceBundleChromosomes: sourceBundleChromosomes,
                        variantChromosomes: sourceDB.allChromosomes(),
                        variantChromosomeMaxPositions: sourceDB.chromosomeMaxPositions()
                    )
                    let sanitizedTrackID = BundleBuildHelpers.sanitizedFilename(sourceTrack.id)
                    let trackID = sanitizedTrackID.isEmpty ? UUID().uuidString : sanitizedTrackID
                    let dbFilename = "variants_\(trackIndex)_\(trackID).db"
                    let dbURL = variantsDir.appendingPathComponent(dbFilename)

                    let variantCount = try sourceDB.extractRegion(
                        chromosome: result.chromosome,
                        chromosomeAliases: chromosomeAliases,
                        start: result.effectiveStart,
                        end: result.effectiveEnd,
                        outputURL: dbURL,
                        newChromosome: newChromName,
                        sampleFilter: sampleFilter
                    )

                    guard variantCount > 0 else {
                        try? fileManager.removeItem(at: dbURL)
                        continue
                    }
                    provenanceOutputURLs.append(dbURL)

                    let relativePath = "variants/\(dbFilename)"
                    variantTracks.append(VariantTrackInfo(
                        id: sourceTrack.id,
                        name: sourceTrack.name,
                        description: "Variants extracted from \(result.chromosome):\(result.effectiveStart)-\(result.effectiveEnd)",
                        path: relativePath,
                        indexPath: relativePath,
                        databasePath: relativePath,
                        variantType: sourceTrack.variantType,
                        variantCount: variantCount
                    ))
                    extractionLogger.info("buildBundle: Extracted \(variantCount) variants for track \(sourceTrack.id)")
                } catch {
                    extractionLogger.warning("buildBundle: Variant extraction failed for track \(sourceTrack.id, privacy: .public) (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Write manifest
        progressHandler?(0.88, "Writing manifest...")
        let coordinateLabel = "\(result.chromosome):\(result.effectiveStart)-\(result.effectiveEnd)"
        let description: String
        if let source = sourceBundleName {
            description = "Extracted from \(source) at \(coordinateLabel)"
        } else {
            description = "Extracted sequence at \(coordinateLabel)"
        }

        let sourceInfo = SourceInfo(
            organism: sourceBundleName ?? "Unknown",
            commonName: nil,
            taxonomyId: nil,
            assembly: "Extracted",
            assemblyAccession: nil,
            database: nil,
            sourceURL: nil,
            downloadDate: Date(),
            notes: description
        )

        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: hasGzi ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let identifier = "org.lungfish.extracted.\(bundleName.lowercased().replacingOccurrences(of: " ", with: "-"))"

        let manifestName = desiredBundleName ?? result.sourceName
        let manifest = BundleManifest(
            name: manifestName,
            identifier: identifier,
            description: description,
            source: sourceInfo,
            genome: genomeInfo,
            annotations: annotationTracks,
            variants: variantTracks
        )

        try manifest.save(to: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        provenanceOutputURLs.append(manifestURL)

        progressHandler?(0.96, "Writing provenance...")
        let completedAt = Date()
        do {
            try Self.writeProvenance(
                result: result,
                bundleURL: bundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sourceAnnotationTracks: sourceAnnotationTracks,
                sourceVariantTracks: sourceVariantTracks,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated,
                outputURLs: provenanceOutputURLs,
                startedAt: startedAt,
                completedAt: completedAt
            )
        } catch {
            try? fileManager.removeItem(at: bundleURL)
            throw error
        }

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        extractionLogger.info("buildBundle: Bundle complete at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }

    private static func writeProvenance(
        result: LungfishCore.ExtractionResult,
        bundleURL: URL,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sourceAnnotationTracks: [SourceAnnotationTrack],
        sourceVariantTracks: [SourceVariantTrack],
        sampleFilter: Set<String>?,
        isConcatenated: Bool,
        outputURLs: [URL],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv = extractionProvenanceArguments(
            result: result,
            bundleURL: bundleURL,
            sourceBundleURL: sourceBundleURL,
            sourceBundleName: sourceBundleName,
            desiredBundleName: desiredBundleName,
            sampleFilter: sampleFilter,
            isConcatenated: isConcatenated
        )
        let inputDescriptors = try provenanceInputDescriptors(
            sourceBundleURL: sourceBundleURL,
            sourceAnnotationTracks: sourceAnnotationTracks,
            sourceVariantTracks: sourceVariantTracks
        )
        let outputDescriptors = try outputURLs.map {
            try ProvenanceFileDescriptor.file(
                url: $0,
                format: provenanceFormat(for: $0),
                role: provenanceOutputRole(for: $0)
            )
        }
        let step = ProvenanceStep(
            toolName: "lungfish gui sequence extraction",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )

        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish gui sequence extraction",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish gui sequence extraction",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .reproducibleCommand(argv.map(shellEscape).joined(separator: " "))
        .options(
            explicit: extractionExplicitOptions(
                result: result,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            ),
            defaults: [
                "reverse_complement": .boolean(false),
                "concatenate_exons": .boolean(false),
                "sample_filter": .array([]),
            ],
            resolved: extractionResolvedOptions(
                result: result,
                bundleURL: bundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            )
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private static func extractionProvenanceArguments(
        result: LungfishCore.ExtractionResult,
        bundleURL: URL,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String] {
        var argv = [
            "lungfish-gui",
            "sequence",
            "extract-bundle",
        ]
        if let sourceBundleURL {
            argv += ["--source-bundle", sourceBundleURL.path]
        }
        if let sourceBundleName, !sourceBundleName.isEmpty {
            argv += ["--source-name", sourceBundleName]
        }
        argv += [
            "--chromosome", result.chromosome,
            "--start", String(result.effectiveStart),
            "--end", String(result.effectiveEnd),
        ]
        if result.isReverseComplement {
            argv.append("--reverse-complement")
        }
        if isConcatenated {
            argv.append("--concatenate-exons")
        }
        if let desiredBundleName, !desiredBundleName.isEmpty {
            argv += ["--name", desiredBundleName]
        }
        if let sampleFilter, !sampleFilter.isEmpty {
            argv += ["--samples", sampleFilter.sorted().joined(separator: ",")]
        }
        argv += ["--output", bundleURL.path]
        return argv
    }

    private static func extractionExplicitOptions(
        result: LungfishCore.ExtractionResult,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String: ParameterValue] {
        [
            "operation": .string("sequence-extraction"),
            "source_name": .string(result.sourceName),
            "source_bundle": sourceBundleURL.map(ParameterValue.file) ?? .null,
            "source_bundle_name": sourceBundleName.map(ParameterValue.string) ?? .null,
            "bundle_name": desiredBundleName.map(ParameterValue.string) ?? .string(result.sourceName),
            "reverse_complement": .boolean(result.isReverseComplement),
            "concatenate_exons": .boolean(isConcatenated),
            "sample_filter": .array((sampleFilter ?? []).sorted().map { .string($0) }),
        ]
    }

    private static func extractionResolvedOptions(
        result: LungfishCore.ExtractionResult,
        bundleURL: URL,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String: ParameterValue] {
        [
            "operation": .string("sequence-extraction"),
            "source_name": .string(result.sourceName),
            "source_bundle": sourceBundleURL.map(ParameterValue.file) ?? .null,
            "source_bundle_name": sourceBundleName.map(ParameterValue.string) ?? .null,
            "bundle_name": desiredBundleName.map(ParameterValue.string) ?? .string(result.sourceName),
            "output_bundle": .file(bundleURL),
            "chromosome": .string(result.chromosome),
            "start": .integer(result.effectiveStart),
            "end": .integer(result.effectiveEnd),
            "coordinate_system": .string("0-based half-open"),
            "reverse_complement": .boolean(result.isReverseComplement),
            "concatenate_exons": .boolean(isConcatenated),
            "sample_filter": .array((sampleFilter ?? []).sorted().map { .string($0) }),
        ]
    }

    private static func provenanceInputDescriptors(
        sourceBundleURL: URL?,
        sourceAnnotationTracks: [SourceAnnotationTrack],
        sourceVariantTracks: [SourceVariantTrack]
    ) throws -> [ProvenanceFileDescriptor] {
        var inputURLs: [URL] = []
        if let sourceBundleURL {
            inputURLs.append(contentsOf: sourceBundleInputURLs(sourceBundleURL))
        }
        inputURLs.append(contentsOf: sourceAnnotationTracks.map(\.databaseURL))
        inputURLs.append(contentsOf: sourceVariantTracks.map(\.databaseURL))

        var seen = Set<String>()
        var descriptors: [ProvenanceFileDescriptor] = []
        for url in inputURLs {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            guard seen.insert(standardized.path).inserted else { continue }
            descriptors.append(try ProvenanceFileDescriptor.file(
                url: standardized,
                format: provenanceFormat(for: standardized),
                role: provenanceInputRole(for: standardized)
            ))
        }
        return descriptors
    }

    private static func sourceBundleInputURLs(_ sourceBundleURL: URL) -> [URL] {
        var urls = [sourceBundleURL.appendingPathComponent("manifest.json")]
        guard let manifest = try? BundleManifest.load(from: sourceBundleURL),
              let genome = manifest.genome else {
            return urls
        }
        urls.append(sourceBundleURL.appendingPathComponent(genome.path))
        urls.append(sourceBundleURL.appendingPathComponent(genome.indexPath))
        if let gzipIndexPath = genome.gzipIndexPath {
            urls.append(sourceBundleURL.appendingPathComponent(gzipIndexPath))
        }
        return urls
    }

    private static func provenanceInputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .input
        }
    }

    private static func provenanceOutputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .output
        }
    }

    private static func provenanceFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "bed":
            return .bed
        case "json":
            return .json
        case "fai", "gzi", "txt":
            return .text
        case "fa", "fasta", "fna", "ffn", "faa", "fas":
            return .fasta
        case "gz" where filename.hasSuffix(".fa.gz")
            || filename.hasSuffix(".fasta.gz")
            || filename.hasSuffix(".fna.gz")
            || filename.hasSuffix(".ffn.gz")
            || filename.hasSuffix(".faa.gz")
            || filename.hasSuffix(".fas.gz"):
            return .fasta
        case "db":
            return .unknown
        default:
            return .unknown
        }
    }

    /// Resolves variant-track chromosome aliases for extraction.
    ///
    /// Returns ordered candidates to try after the primary source chromosome name.
    /// The source chromosome is intentionally excluded from this return value.
    private static func variantChromosomeAliases(
        sourceChromosome: String,
        sourceBundleChromosomes: [ChromosomeInfo],
        variantChromosomes: [String],
        variantChromosomeMaxPositions: [String: Int]
    ) -> [String] {
        guard !sourceBundleChromosomes.isEmpty, !variantChromosomes.isEmpty else { return [] }

        // Build VCF -> bundle mapping using the same logic used elsewhere in the app.
        let vcfToBundle = mapVCFChromosomes(variantChromosomes, toBundleChromosomes: sourceBundleChromosomes)

        // Resolve requested source chromosome to canonical bundle chromosome name.
        let canonicalBundleChromosome = sourceBundleChromosomes.first {
            $0.name == sourceChromosome || $0.aliases.contains(sourceChromosome)
        }?.name ?? sourceChromosome

        var ordered: [String] = []
        var seen = Set<String>()

        func appendUnique(_ value: String) {
            guard seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        // Include explicit aliases attached to this bundle chromosome.
        if let chromInfo = sourceBundleChromosomes.first(where: { $0.name == canonicalBundleChromosome }) {
            for alias in chromInfo.aliases {
                appendUnique(alias)
            }
        }

        // Include VCF chromosome names that map to the target bundle chromosome.
        for (vcfChromosome, bundleChromosome) in vcfToBundle where bundleChromosome == canonicalBundleChromosome {
            appendUnique(vcfChromosome)
        }

        // Length-based fallback for bundles where aliases were not populated in manifest.
        if ordered.isEmpty,
           let targetChrom = sourceBundleChromosomes.first(where: { $0.name == canonicalBundleChromosome }) {
            var bestChromosome: String?
            var bestDelta = Int64.max
            for (variantChromosome, maxPos) in variantChromosomeMaxPositions {
                let maxPos64 = Int64(maxPos)
                guard maxPos64 <= targetChrom.length else { continue }
                let delta = targetChrom.length - maxPos64
                let tolerance = targetChrom.length > 1_000_000
                    ? targetChrom.length / 20   // 5%
                    : targetChrom.length / 5    // 20%
                guard delta < tolerance else { continue }
                if delta < bestDelta {
                    bestDelta = delta
                    bestChromosome = variantChromosome
                }
            }
            if let bestChromosome {
                appendUnique(bestChromosome)
            }
        }

        return ordered.filter { $0 != sourceChromosome }
    }

    /// Resolves annotation-track chromosome candidates for extraction queries.
    private static func annotationChromosomeCandidates(
        sourceChromosome: String,
        sourceBundleChromosomes: [ChromosomeInfo],
        annotationChromosomes: [String]
    ) -> [String] {
        guard !annotationChromosomes.isEmpty else { return [sourceChromosome] }
        let available = Set(annotationChromosomes)
        var ordered: [String] = []
        var seen = Set<String>()

        func appendIfAvailable(_ value: String) {
            guard available.contains(value) else { return }
            guard seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        appendIfAvailable(sourceChromosome)

        // Bundle alias + VCF/bundle mapping helpers.
        let vcfToBundle = mapVCFChromosomes(annotationChromosomes, toBundleChromosomes: sourceBundleChromosomes)
        let bundleChromosome = sourceBundleChromosomes.first {
            $0.name == sourceChromosome || $0.aliases.contains(sourceChromosome)
        }
        if let bundleChromosome {
            for alias in bundleChromosome.aliases {
                appendIfAvailable(alias)
            }
            for (annotationChromosome, mappedBundleChromosome) in vcfToBundle where mappedBundleChromosome == bundleChromosome.name {
                appendIfAvailable(annotationChromosome)
            }
        }

        // Basic normalization fallbacks.
        if sourceChromosome.hasPrefix("chr") {
            appendIfAvailable(String(sourceChromosome.dropFirst(3)))
        } else {
            appendIfAvailable("chr" + sourceChromosome)
        }
        if let dot = sourceChromosome.firstIndex(of: ".") {
            appendIfAvailable(String(sourceChromosome[..<dot]))
        }

        return ordered.isEmpty ? [sourceChromosome] : ordered
    }
}
