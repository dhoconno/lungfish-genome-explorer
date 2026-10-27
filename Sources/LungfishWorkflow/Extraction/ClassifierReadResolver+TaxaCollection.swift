// ClassifierReadResolver+TaxaCollection.swift - A taxa collection's reads through the resolver, one file per taxon
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let collectionLogger = Logger(subsystem: "com.lungfish.workflow", category: "ClassifierReadResolver")

extension ClassifierReadResolver {

    /// Extracts the reads of every taxon of `collection` from the Kraken2 result at `resultPath`, one
    /// gzip FASTQ per taxon in `outputDirectory`, the files `lungfish-cli extract taxa-collection` writes
    /// (Phase 2.12 lane 12.11). Each taxon runs through the Kraken2 path of this resolver with its own
    /// scope, so a collection picks reads as `extract reads --by-classifier` does. A file is named after
    /// the taxon's display name and tax ID and holds each pair's mates together, then the single reads.
    /// Beside it go the roles of a mix of pairs and single reads and its own record, which names the
    /// command for that one taxon (``collectionTaxonCommand(_:collection:resultPath:outputDirectory:)``).
    /// A taxon without reads in the report, or without reads under its scope, is skipped and counted. A
    /// file of the folder that this run does not write is never touched (BIO's ruling, section 1).
    ///
    /// - Returns: The file of each taxon that gave reads, in the order of the collection.
    public func extractCollection(
        _ collection: TaxaCollection,
        resultPath: URL,
        classification: ClassificationResult,
        outputDirectory: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [URL] {
        let targets = collection.taxa
        guard !targets.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        progress?(0.0, "Starting batch extraction: \(collection.name) (\(targets.count) taxa)")
        let scratch = try ProjectTempDirectory.create(prefix: "taxa-collection-", in: Self.resolveProjectRoot(from: resultPath))
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The result's read files, resolved once for every taxon as extractBatch did, so a trimmed or
        // oriented subset is materialized once into the scratch folder (the review of lane 12.11 c4, fix 5).
        let sources = try await collectionSources(of: classification, targets: targets, scratch: scratch)

        var outputs: [URL] = []
        var skipped = 0
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let base = Double(index) / Double(targets.count)
            let step = 1.0 / Double(targets.count)
            guard (classification.tree.node(taxId: target.taxId)?.readsClade ?? 0) > 0 else {
                collectionLogger.info("Skipping \(target.displayName, privacy: .public): 0 reads in result")
                skipped += 1
                progress?(base + step, "Skipped \(target.displayName) (0 reads)")
                continue
            }
            progress?(base, "Extracting \(target.displayName) (\(index + 1) of \(targets.count))...")
            do {
                outputs.append(try await extractCollectionTaxon(
                    target, of: collection, resultPath: resultPath, classification: classification,
                    outputDirectory: outputDirectory, scratch: scratch, sources: sources,
                    progress: { fraction, message in progress?(min(base + step * fraction, base + step), message) }
                ))
            } catch TaxonomyExtractionError.noMatchingReads, ClassifierExtractionError.zeroReadsExtracted {
                // The resolver gives noMatchingReads unchanged for a taxon with no read under its scope, such as an
                // exact taxon with none of its own (TaxonomyExtractionPipeline.extractEachSource), and
                // zeroReadsExtracted when its files hold none. Both are the skip extractBatch gave the first. Any
                // other error, an empty seqkit output included, fails the batch as it did.
                collectionLogger.info("No matching reads for \(target.displayName, privacy: .public), skipping")
                skipped += 1
                progress?(base + step, "Skipped \(target.displayName) (no matching reads)")
            } catch ClassifierExtractionError.allSamplesSkipped {
                // The resolver skips a sample whose read files it cannot find. A collection reads one
                // result, so that is the missing source, a failure in the words extractBatch gave.
                throw ClassifierExtractionError.kraken2SourceMissing
            }
        }
        progress?(1.0, "Batch complete: \(outputs.count) of \(targets.count) taxa extracted (\(skipped) skipped)")
        collectionLogger.info("Batch extraction complete: \(outputs.count) extracted, \(skipped) skipped from \(collection.name, privacy: .public)")
        return outputs
    }

    /// The read files of the collection's result, resolved once before its taxa into
    /// `scratch/materialized`, which goes with `scratch`. Nothing is resolved when no taxon holds reads in
    /// the report, since every taxon is then skipped. Files that cannot be resolved fail the collection
    /// in the words of the missing source, as a resolve for each taxon did through `allSamplesSkipped`.
    private func collectionSources(
        of classification: ClassificationResult, targets: [TaxonTarget], scratch: URL
    ) async throws -> KrakenResultReadSources? {
        guard targets.contains(where: { (classification.tree.node(taxId: $0.taxId)?.readsClade ?? 0) > 0 }) else {
            return nil
        }
        do {
            return try await KrakenResultReadSources.resolve(
                result: classification,
                materializationDirectory: scratch.appendingPathComponent("materialized", isDirectory: true)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ClassifierExtractionError.sourceNotInProject(let place, let action) {
            throw ClassifierExtractionError.sourceNotInProject(place: place, action: action)
        } catch {
            collectionLogger.warning(
                "Source FASTQ not found: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw ClassifierExtractionError.kraken2SourceMissing
        }
    }

    /// The command a collection file's record names, `extract taxa-collection` for that one taxon into
    /// the same folder, whose replay writes the same file (BIO 6, the review of lane 12.11, fix 8d). The
    /// target carries the scope, `exact` for a taxon without its children.
    public static func collectionTaxonCommand(
        _ target: TaxonTarget, collection: TaxaCollection, resultPath: URL, outputDirectory: URL
    ) -> [String] {
        [
            CLICommandIdentity.executableName, "extract", "taxa-collection",
            "--result", resultPath.path,
            "--collection-id", collection.id,
            "--collection-name", collection.name,
            "--target", "\(target.taxId),\(target.includeChildren ? "children" : "exact"),\(target.displayName)",
            "--output-dir", outputDirectory.path,
        ]
    }

    /// One taxon of a collection: the resolver's Kraken2 extraction into `scratch`, gzipped into
    /// `outputDirectory` under the taxon's name, with its roles and its record beside it.
    private func extractCollectionTaxon(
        _ target: TaxonTarget,
        of collection: TaxaCollection,
        resultPath: URL,
        classification: ClassificationResult,
        outputDirectory: URL,
        scratch: URL,
        sources: KrakenResultReadSources?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let runClock = ProvenanceRunClock()
        let scope: TaxonScope = target.includeChildren ? .children : .exact
        let safeName = target.displayName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let baseName = ExtractionBundleNaming.sanitizeFilename("\(safeName)_taxid\(target.taxId)")
        let plain = scratch.appendingPathComponent("\(baseName).fastq")
        defer { try? FileManager.default.removeItem(at: plain) }
        let extraction = try await extractViaKraken2(
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [target.taxId])],
            resultPath: resultPath,
            options: ExtractionOptions(format: .fastq, taxonScope: scope),
            destination: .file(plain),
            runClock: runClock,
            resolvedSources: sources,
            progress: progress
        )
        try Task.checkCancellation()
        let output = outputDirectory.appendingPathComponent("\(baseName).fastq.gz")
        try KrakenOutputCompactor.gzipCopy(source: plain, destination: output)
        if let roles = extraction.layout.roles(namedFor: output) {
            FASTQMixedLayoutHint.write(roles, beside: output)
        }
        try await TaxonomyExtractionPipeline().recordProvenance(
            config: TaxonomyExtractionConfig(
                taxIds: [target.taxId],
                includeChildren: scope.includesChildren,
                sourceFiles: extraction.sourceFiles,
                outputFiles: [output],
                classificationOutput: classification.outputURL,
                taxonomyReport: scope.includesChildren ? classification.reportURL : nil,
                keepReadPairs: true
            ),
            resolvedTaxIds: scope.resolvedTaxIds([target.taxId], in: classification.tree),
            outputURLs: [output],
            extractedCount: extraction.outcome.readCount,
            runtime: runClock.elapsed,
            command: Self.collectionTaxonCommand(
                target, collection: collection, resultPath: resultPath, outputDirectory: outputDirectory
            )
        )
        return output
    }
}
