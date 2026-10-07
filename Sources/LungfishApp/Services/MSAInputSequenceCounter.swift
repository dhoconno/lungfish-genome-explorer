// MSAInputSequenceCounter.swift - how many sequences the MAFFT pane would align
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Resolves the "All sequences (N)" count the MAFFT pane shows for a set of
/// dialog inputs. The viewer route already knows its record count; the Tools
/// menu route reaches the dialog from sidebar selections and has to derive it
/// from the inputs themselves.
///
/// Every function here reads files, so callers on the main actor should await
/// from a detached task. Inputs that cannot be counted contribute zero rather
/// than failing the dialog.
enum MSAInputSequenceCounter {
    /// Sum of `sequenceCount(for:)` across all inputs, skipping any that cannot be resolved.
    static func sequenceCount(for inputURLs: [URL]) async -> Int {
        var total = 0
        for url in inputURLs {
            total += await sequenceCount(for: url) ?? 0
        }
        return total
    }

    /// Records in one input: a `.lungfishref` bundle, a `.lungfishfastq` bundle,
    /// or a loose FASTA/FASTQ file (gzip accepted). `nil` when the input has no
    /// readable sequence payload.
    static func sequenceCount(for inputURL: URL) async -> Int? {
        let standardized = inputURL.standardizedFileURL
        if let bundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: standardized),
           let count = referenceBundleSequenceCount(in: bundleURL) {
            return count
        }
        // An oriented, subset or trimmed dataset's reads are a recipe over its
        // root; the resolver would count the root's reads. Its manifest records
        // the dataset's own count.
        if let derivedBundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: standardized) {
            let readCount = FASTQBundle.loadDerivedManifest(in: derivedBundleURL)?.cachedStatistics.readCount ?? 0
            return readCount > 0 ? readCount : nil
        }
        // Every file MAFFT reads for the input, every chunk of a chunked root
        // and both mate files of a paired derivative. The one-file resolution
        // counted the first file only (Phase 2.1 lane L3). A virtual bundle
        // is counted from its manifest above, so nothing is materialized.
        guard let sequenceURLs = try? await DerivedFASTQBundleInput.readableURLs(
            for: standardized,
            in: FileManager.default.temporaryDirectory
                .appendingPathComponent("msa-input-count-\(UUID().uuidString)", isDirectory: true),
            materializer: { bundleURL, _ in throw CountingMaterializesNothing(bundlePath: bundleURL.path) }
        ), !sequenceURLs.isEmpty else {
            return nil
        }
        var total = 0
        for sequenceURL in sequenceURLs {
            guard let format = SequenceFormat.from(url: sequenceURL) else { return nil }
            let count: Int?
            switch format {
            case .fasta:
                count = fastaRecordCount(at: sequenceURL)
            case .fastq:
                count = try? await FASTQReader(validateSequence: false).countRecords(in: sequenceURL)
            }
            guard let count else { return nil }
            total += count
        }
        return total
    }

    /// A virtual bundle reaching the read-set resolver here, which would
    /// have to be materialized to be counted.
    private struct CountingMaterializesNothing: Error {
        let bundlePath: String
    }

    /// The manifest's chromosome list is the record count of the bundle genome.
    /// Older or minimal manifests may leave it empty, so fall back to the FASTA
    /// index (one line per record) and then to the genome file itself.
    static func referenceBundleSequenceCount(in bundleURL: URL) -> Int? {
        guard let manifest = try? BundleManifest.load(from: bundleURL),
              let genome = manifest.genome else { return nil }
        if !genome.chromosomes.isEmpty {
            return genome.chromosomes.count
        }
        let indexURL = bundleURL.appendingPathComponent(genome.indexPath)
        if let indexed = faiRecordCount(at: indexURL) {
            return indexed
        }
        return fastaRecordCount(at: bundleURL.appendingPathComponent(genome.path))
    }

    /// Number of records listed in a samtools `.fai` index.
    static func faiRecordCount(at indexURL: URL) -> Int? {
        guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else { return nil }
        let count = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
        return count > 0 ? count : nil
    }

    /// Streams the file through the FASTA reader (gzip-aware) and counts records.
    static func fastaRecordCount(at fastaURL: URL) -> Int? {
        guard let reader = try? FASTAReader(url: fastaURL) else { return nil }
        var count = 0
        do {
            try reader.forEachSequenceSync { _ in count += 1 }
        } catch {
            return nil
        }
        return count
    }
}
