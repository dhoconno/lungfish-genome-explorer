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
        from result: ExtractionResult,
        outputDirectory: URL,
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

        progressHandler?(0.05, "Checking tools...")
        try await BundleBuildHelpers.validateTools(using: toolRunner)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
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
        try fileManager.moveItem(at: compressedFASTA, to: genomeDir.appendingPathComponent("sequence.fa.gz"))
        try fileManager.moveItem(at: faiURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"))
        let hasGzi = fileManager.fileExists(atPath: gziURL.path)
        if hasGzi {
            try fileManager.moveItem(at: gziURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.gzi"))
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

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        extractionLogger.info("buildBundle: Bundle complete at \(bundleURL.path, privacy: .public)")
        return bundleURL
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
