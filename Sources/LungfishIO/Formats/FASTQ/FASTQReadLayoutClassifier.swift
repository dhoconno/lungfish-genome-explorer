// FASTQReadLayoutClassifier.swift - Detects interleaved, mixed, and single-end FASTQ layouts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - FASTQReadLayout

/// How the records of a single FASTQ file relate to one another.
public enum FASTQReadLayout: String, Codable, Sendable, Equatable {
    /// No record has its mate next to it.
    case singleEnd = "single_end"
    /// Every record is immediately followed (or preceded) by its mate.
    case strictlyInterleaved = "strictly_interleaved"
    /// Adjacent mate pairs mixed with unpaired records (merged or orphan reads),
    /// or a file the bundle metadata calls paired or merged but whose records do
    /// not alternate strictly.
    case mixedInterleaved = "mixed_interleaved"
}

// MARK: - FASTQPairingMetadataHints

/// Metadata evidence about a FASTQ file's pairing, gathered from the bundle
/// manifest and the FASTQ sidecar. Content scanning always runs as well; the
/// hints can only make the result more conservative (mixed instead of strict).
public struct FASTQPairingMetadataHints: Codable, Sendable, Equatable {
    /// The recorded pairing mode, if any.
    public var pairingMode: IngestionMetadata.PairingMode?
    /// Where the recorded pairing mode came from, when the metadata says.
    /// `nil` for metadata that predates `IngestionMetadata.pairingSource`
    /// and for a derived manifest, whose pairing is inherited, not chosen.
    public var pairingSource: IngestionMetadata.PairingSource?
    /// Whether metadata records merged reads or orphans inside this dataset
    /// (a read classification with merged or unpaired reads, a paired-end
    /// merge in the derivative lineage, or a merge step in the applied recipe).
    public var hasMergedOrUnpairedReads: Bool
    /// Human-readable description of where the merge evidence came from.
    public var mergeEvidence: String?

    public init(
        pairingMode: IngestionMetadata.PairingMode? = nil,
        pairingSource: IngestionMetadata.PairingSource? = nil,
        hasMergedOrUnpairedReads: Bool = false,
        mergeEvidence: String? = nil
    ) {
        self.pairingMode = pairingMode
        self.pairingSource = pairingSource
        self.hasMergedOrUnpairedReads = hasMergedOrUnpairedReads
        self.mergeEvidence = mergeEvidence
    }

    /// Whether metadata says the file carries mates of paired-end fragments.
    public var claimsPairedContent: Bool {
        pairingMode == .interleaved || pairingMode == .pairedEnd
    }

    /// Whether a user explicitly declared the reads single-end.
    ///
    /// This is the only recorded pairing that settles a layout without reading
    /// the records. A `single_end` that an importer fell back to (or that
    /// predates `pairingSource`) is not: such bundles exist whose file
    /// alternates `/1` `/2` mates (imports with no pairing choice before
    /// 2026-09-25).
    public var recordsExplicitSingleEnd: Bool {
        pairingMode == .singleEnd && pairingSource == .explicit
    }
}

// MARK: - FASTQReadLayoutClassification

/// The result of classifying one FASTQ file, suitable for provenance.
public struct FASTQReadLayoutClassification: Codable, Sendable, Equatable {
    public let layout: FASTQReadLayout
    /// Number of records examined.
    public let scannedRecords: Int
    /// Number of adjacent mate pairs found among the scanned records.
    public let matePairs: Int
    /// Number of scanned records without an adjacent mate.
    public let unpairedRecords: Int
    /// Whether the scan read the whole file (false when it stopped at the record limit).
    public let scannedWholeFile: Bool
    /// The metadata hints that were considered.
    public let metadata: FASTQPairingMetadataHints
    /// Plain-language reason for the classification.
    public let reason: String

    public init(
        layout: FASTQReadLayout,
        scannedRecords: Int,
        matePairs: Int,
        unpairedRecords: Int,
        scannedWholeFile: Bool,
        metadata: FASTQPairingMetadataHints,
        reason: String
    ) {
        self.layout = layout
        self.scannedRecords = scannedRecords
        self.matePairs = matePairs
        self.unpairedRecords = unpairedRecords
        self.scannedWholeFile = scannedWholeFile
        self.metadata = metadata
        self.reason = reason
    }
}

// MARK: - FASTQReadLayoutClassifier

/// Classifies a FASTQ file as single-end, strictly interleaved, or mixed.
///
/// Two adjacent records are mates when LGE's existing read-pair rule
/// (``ReadPair/parse(from:)``: `/1` `/2` suffixes, or Illumina ` 1:N:` / ` 2:N:`
/// comments) gives the same pair ID with read 1 followed by read 2. Records
/// with no pair marker are mates when their read IDs are identical (the
/// BBTools and SRA convention). The scan is bounded by ``defaultRecordLimit``.
public enum FASTQReadLayoutClassifier {

    /// Default number of records scanned. Even, so a limit never splits a pair.
    public static let defaultRecordLimit = 100_000

    // MARK: Pairing rule

    /// Returns true when `second` is the read-2 mate of `first`.
    ///
    /// - Parameters:
    ///   - first: Full header line of the earlier record, without the leading `@`.
    ///   - second: Full header line of the next record, without the leading `@`.
    public static func areMates(_ first: String, _ second: String) -> Bool {
        let firstPair = pairInfo(first)
        let secondPair = pairInfo(second)
        if let firstPair, let secondPair {
            return firstPair.pairId == secondPair.pairId
                && firstPair.readNumber == 1
                && secondPair.readNumber == 2
        }
        if firstPair == nil, secondPair == nil {
            let firstID = readID(first)
            return !firstID.isEmpty && firstID == readID(second)
        }
        return false
    }

    /// `/1` `/2` on the read ID (even when a comment follows), else the
    /// Illumina ` 1:N:` / ` 2:N:` comment on the full header.
    private static func pairInfo(_ header: String) -> ReadPair? {
        ReadPair.parse(from: String(readID(header))) ?? ReadPair.parse(from: header)
    }

    private static func readID(_ header: String) -> Substring {
        let trimmed = header.drop(while: { $0 == "@" })
        if let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return trimmed[..<end]
        }
        return trimmed
    }

    // MARK: Pure classification

    /// Classifies a list of record headers (without the leading `@`).
    ///
    /// - Parameters:
    ///   - headers: Header lines in file order.
    ///   - scannedWholeFile: Whether `headers` covers the whole file.
    ///   - metadata: Bundle and sidecar evidence.
    public static func classify(
        headers: [String],
        scannedWholeFile: Bool,
        metadata: FASTQPairingMetadataHints = FASTQPairingMetadataHints()
    ) -> FASTQReadLayoutClassification {
        var pairs = 0
        var unpaired = 0
        var index = 0
        while index < headers.count {
            if index + 1 < headers.count, areMates(headers[index], headers[index + 1]) {
                pairs += 1
                index += 2
                continue
            }
            // A truncated scan can end halfway through a pair: do not count
            // the final record against strictness when the file continues.
            if index == headers.count - 1, !scannedWholeFile {
                index += 1
                continue
            }
            unpaired += 1
            index += 1
        }

        let layout: FASTQReadLayout
        let reason: String
        let scope = scannedWholeFile
            ? "all \(headers.count) records"
            : "the first \(headers.count) records"

        if pairs > 0, unpaired == 0 {
            if metadata.hasMergedOrUnpairedReads {
                layout = .mixedInterleaved
                reason = "Mates alternate in \(scope), but the dataset metadata records merged or unpaired reads (\(metadata.mergeEvidence ?? "merge evidence"))."
            } else {
                layout = .strictlyInterleaved
                reason = "Every record in \(scope) is followed by its mate."
            }
        } else if pairs > 0 {
            layout = .mixedInterleaved
            reason = "\(scope.prefix(1).uppercased() + scope.dropFirst()) hold \(pairs) adjacent mate pairs and \(unpaired) unpaired reads (merged or orphan)."
        } else if metadata.claimsPairedContent || metadata.hasMergedOrUnpairedReads {
            layout = .mixedInterleaved
            reason = "The dataset metadata says it holds paired\(metadata.hasMergedOrUnpairedReads ? " and merged" : "") reads, but no adjacent mates were found in \(scope)."
        } else {
            layout = .singleEnd
            reason = headers.isEmpty
                ? "No FASTQ records could be read."
                : "No record in \(scope) is followed by its mate."
        }

        return FASTQReadLayoutClassification(
            layout: layout,
            scannedRecords: headers.count,
            matePairs: pairs,
            unpairedRecords: unpaired,
            scannedWholeFile: scannedWholeFile,
            metadata: metadata,
            reason: reason
        )
    }

    // MARK: File scanning

    private struct StopScan: Error {}

    /// Reads up to `limit` record headers from a 4-line FASTQ file (plain or gzip).
    ///
    /// Stops early (returning what was read) if a header line does not start with `@`.
    public static func readHeaders(
        from fastqURL: URL,
        limit: Int = defaultRecordLimit
    ) throws -> (headers: [String], scannedWholeFile: Bool) {
        var headers: [String] = []
        var lineIndex = 0
        var reachedLimit = false
        do {
            try fastqURL.forEachLineAutoDecompressing { line in
                defer { lineIndex += 1 }
                guard lineIndex % 4 == 0 else { return }
                if line.isEmpty { return }
                guard line.hasPrefix("@") else { throw StopScan() }
                if headers.count >= limit {
                    reachedLimit = true
                    throw StopScan()
                }
                headers.append(String(line.dropFirst()))
            }
        } catch is StopScan {
            // Bounded early exit.
        }
        return (headers, !reachedLimit)
    }

    /// Classifies a FASTQ file or `.lungfishfastq` bundle.
    ///
    /// For a bundle, metadata comes from `derived.manifest.json`,
    /// `read-manifest.json`, and the primary FASTQ sidecar; the scanned file is
    /// the bundle's primary physical FASTQ (for a virtual bundle, its preview).
    public static func classify(
        inputURL: URL,
        limit: Int = defaultRecordLimit
    ) -> FASTQReadLayoutClassification {
        let metadata = metadataHints(for: inputURL)
        let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: inputURL)
        guard let fastqURL,
              let scan = try? readHeaders(from: fastqURL, limit: limit) else {
            return classify(headers: [], scannedWholeFile: true, metadata: metadata)
        }
        return classify(headers: scan.headers, scannedWholeFile: scan.scannedWholeFile, metadata: metadata)
    }

    /// Gathers pairing and merge evidence from bundle and sidecar metadata.
    public static func metadataHints(for inputURL: URL) -> FASTQPairingMetadataHints {
        var hints = FASTQPairingMetadataHints()
        var evidence: [String] = []

        let bundleURL: URL? = FASTQBundle.isBundleURL(inputURL)
            ? inputURL
            : {
                let parent = inputURL.deletingLastPathComponent()
                return FASTQBundle.isBundleURL(parent) ? parent : nil
            }()

        if let bundleURL {
            if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                hints.pairingMode = manifest.pairingMode
                if let classification = manifest.readClassification,
                   classification.mergedReadCount > 0 || classification.unpairedReadCount > 0 {
                    evidence.append("derived manifest: \(classification.compositionLabel)")
                }
                if manifest.lineage.contains(where: { $0.kind == .pairedEndMerge })
                    || manifest.operation.kind == .pairedEndMerge {
                    evidence.append("paired-end merge in derivative lineage")
                }
            }
            if let readManifest = ReadManifest.load(from: bundleURL) {
                let classification = readManifest.classification
                if classification.mergedReadCount > 0 || classification.unpairedReadCount > 0 {
                    evidence.append("read manifest: \(classification.compositionLabel)")
                }
            }
        }

        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: inputURL),
           let sidecar = FASTQMetadataStore.load(for: fastqURL) {
            if hints.pairingMode == nil {
                hints.pairingMode = sidecar.ingestion?.pairingMode
            }
            // The source travels with the mode it describes: a derived
            // manifest that records a different pairing does not inherit the
            // sidecar's explicitness.
            if let ingestion = sidecar.ingestion, ingestion.pairingMode == hints.pairingMode {
                hints.pairingSource = ingestion.pairingSource
            }
            if let classification = sidecar.readClassification,
               classification.mergedReadCount > 0 || classification.unpairedReadCount > 0 {
                evidence.append("sidecar: \(classification.compositionLabel)")
            }
            if let recipe = sidecar.ingestion?.recipeApplied,
               recipe.stepResults.contains(where: { $0.stepName.lowercased().contains("merge") }) {
                evidence.append("recipe \(recipe.recipeName) merges overlapping pairs")
            }
        }

        if !evidence.isEmpty {
            hints.hasMergedOrUnpairedReads = true
            hints.mergeEvidence = evidence.joined(separator: "; ")
        }
        return hints
    }
}
