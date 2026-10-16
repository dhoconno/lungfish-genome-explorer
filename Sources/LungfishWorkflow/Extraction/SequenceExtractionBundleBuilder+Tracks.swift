// SequenceExtractionBundleBuilder+Tracks.swift - The region bundle that keeps the source bundle's tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let trackLogger = Logger(subsystem: LogSubsystem.workflow, category: "SequenceExtraction")

/// An annotation track of the source bundle whose features in the region the extracted bundle keeps.
package struct SequenceExtractionSourceAnnotationTrack: Sendable {
    package let id: String
    package let name: String
    package let databaseURL: URL
    package let annotationType: AnnotationTrackType

    package init(id: String, name: String, databaseURL: URL, annotationType: AnnotationTrackType) {
        self.id = id
        self.name = name
        self.databaseURL = databaseURL
        self.annotationType = annotationType
    }
}

/// A variant track of the source bundle whose calls in the region the extracted bundle keeps.
package struct SequenceExtractionSourceVariantTrack: Sendable {
    package let id: String
    package let name: String
    package let databaseURL: URL
    package let variantType: VariantTrackType

    package init(id: String, name: String, databaseURL: URL, variantType: VariantTrackType) {
        self.id = id
        self.name = name
        self.databaseURL = databaseURL
        self.variantType = variantType
    }
}

extension SequenceExtractionBundleBuilder {

    /// Builds `<bundleName>.lungfishref` in `outputDirectory` from the region's FASTA at `fastaURL`
    /// with bgzip and samtools faidx, keeps the source tracks' features and calls in the region at
    /// the region's coordinates, the calls only for the samples of the filter, and writes the
    /// manifest. The caller publishes the bundle and writes its one record. Moved from the app's
    /// `SequenceExtractionPipeline` (2.11 A48 M1).
    func buildTrackBundle(
        request: SequenceExtractionBundleBuildRequest,
        fastaURL: URL,
        bundleName: String,
        outputDirectory: URL,
        tempDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        let fileManager = FileManager.default
        let result = request.result

        progressHandler?(0.15, "Checking tools...")
        try await BundleBuildHelpers.validateTools(using: toolRunner)

        progressHandler?(0.30, "Compressing (bgzip)...")
        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: fastaURL, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }
        let compressedFASTA = fastaURL.appendingPathExtension("gz")

        progressHandler?(0.50, "Indexing (samtools faidx)...")
        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }
        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")
        let chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        progressHandler?(0.70, "Creating bundle...")
        let bundleURL = outputDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try fileManager.moveItem(at: compressedFASTA, to: genomeDir.appendingPathComponent("sequence.fa.gz"))
        try fileManager.moveItem(at: faiURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"))
        let hasGzi = fileManager.fileExists(atPath: gziURL.path)
        if hasGzi {
            try fileManager.moveItem(at: gziURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.gzi"))
        }

        let newChromName = chromosomes.first?.name ?? BundleBuildHelpers.sanitizedFilename(result.sourceName)
        var annotationTracks: [AnnotationTrackInfo] = []
        if !request.isConcatenated, !request.sourceAnnotationTracks.isEmpty {
            progressHandler?(0.78, "Extracting annotations...")
            annotationTracks = try extractAnnotationTracks(
                request: request, newChromName: newChromName, bundleURL: bundleURL, tempDirectory: tempDirectory)
        }
        var variantTracks: [VariantTrackInfo] = []
        if !request.isConcatenated, !request.sourceVariantTracks.isEmpty {
            progressHandler?(0.82, "Extracting variants...")
            variantTracks = try extractVariantTracks(request: request, newChromName: newChromName, bundleURL: bundleURL)
        }

        progressHandler?(0.88, "Writing manifest...")
        let coordinateLabel = "\(result.chromosome):\(result.effectiveStart)-\(result.effectiveEnd)"
        let description: String
        if let source = request.sourceBundleName {
            description = "Extracted from \(source) at \(coordinateLabel)"
        } else {
            description = "Extracted sequence at \(coordinateLabel)"
        }
        let manifest = BundleManifest(
            name: request.desiredBundleName ?? result.sourceName,
            identifier: Self.extractedIdentifier(forBundleNamed: bundleName),
            description: description,
            source: SourceInfo(
                organism: request.sourceBundleName ?? "Unknown",
                commonName: nil,
                taxonomyId: nil,
                assembly: "Extracted",
                assemblyAccession: nil,
                database: nil,
                sourceURL: nil,
                downloadDate: Date(),
                notes: description
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: hasGzi ? "genome/sequence.fa.gz.gzi" : nil,
                totalLength: totalLength,
                chromosomes: chromosomes,
                md5Checksum: nil
            ),
            annotations: annotationTracks,
            variants: variantTracks
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// Copies each source annotation track's features in the region, at the region's coordinates,
    /// into `annotations/`. A `region` feature that spans the extraction is left out, and a track
    /// that fails or keeps no feature is skipped.
    private func extractAnnotationTracks(
        request: SequenceExtractionBundleBuildRequest,
        newChromName: String,
        bundleURL: URL,
        tempDirectory: URL
    ) throws -> [AnnotationTrackInfo] {
        let result = request.result
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        var annotationTracks: [AnnotationTrackInfo] = []
        for (trackIndex, sourceTrack) in request.sourceAnnotationTracks.enumerated() {
            do {
                let sourceDB = try AnnotationDatabase(url: sourceTrack.databaseURL)
                let queryChromosomes = Self.annotationChromosomeCandidates(
                    sourceChromosome: result.chromosome,
                    sourceBundleChromosomes: request.sourceBundleChromosomes,
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
                    // Skip "region" annotations that span the entire extraction. They mark
                    // chromosome or contig bounds and mean nothing in an extracted sub-sequence.
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

                let bedURL = tempDirectory.appendingPathComponent("\(dbFilename).bed")
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
                trackLogger.info("buildBundle: Extracted \(dbRecordCount) annotations for track \(sourceTrack.id)")
            } catch {
                trackLogger.warning("buildBundle: Annotation extraction failed for track \(sourceTrack.id, privacy: .public) (non-fatal): \(error.localizedDescription)")
            }
        }
        return annotationTracks
    }

    /// Copies each source variant track's calls in the region, at the region's coordinates and for
    /// the samples of the filter only, into `variants/`. A track that fails or keeps no call is skipped.
    private func extractVariantTracks(
        request: SequenceExtractionBundleBuildRequest,
        newChromName: String,
        bundleURL: URL
    ) throws -> [VariantTrackInfo] {
        let result = request.result
        let fileManager = FileManager.default
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        var variantTracks: [VariantTrackInfo] = []
        for (trackIndex, sourceTrack) in request.sourceVariantTracks.enumerated() {
            do {
                let sourceDB = try VariantDatabase(url: sourceTrack.databaseURL)
                let chromosomeAliases = Self.variantChromosomeAliases(
                    sourceChromosome: result.chromosome,
                    sourceBundleChromosomes: request.sourceBundleChromosomes,
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
                    sampleFilter: request.sampleFilter,
                    isReverseComplement: result.isReverseComplement
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
                trackLogger.info("buildBundle: Extracted \(variantCount) variants for track \(sourceTrack.id)")
            } catch {
                trackLogger.warning("buildBundle: Variant extraction failed for track \(sourceTrack.id, privacy: .public) (non-fatal): \(error.localizedDescription)")
            }
        }
        return variantTracks
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
