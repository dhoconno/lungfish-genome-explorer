// FASTQInputLayout.swift - The read layouts a FASTQ-consuming tool must declare handling for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// LGE stores a paired import as ONE interleaved FASTQ inside a
// `.lungfishfastq` bundle, mates often carrying identical names. Some bundles
// are MIXED: merged single reads and unmerged pairs in the same file (VSP2 and
// the Illumina amplicon merge recipes). Owner contract (2026-09-24): "our
// settings for tools need to accommodate interleaved files with both kinds of
// reads, defaulting to treating as single reads if both can't be handled
// gracefully." Every tool invocation builder that consumes FASTQ declares what
// it does for each ``FASTQInputLayout`` through a ``FASTQConsumerDeclaration``,
// and `FASTQConsumerRegistryTests` fails when a consumer leaves a layout out.

import Foundation

// MARK: - FASTQInputLayout

/// How the reads handed to a tool are laid out across its input file(s).
public enum FASTQInputLayout: String, Codable, Sendable, CaseIterable, Equatable {
    /// One file (or several pooled files) whose records all stand alone.
    case singleEnd = "single_end"
    /// One file in which every record is followed by its mate.
    case strictlyInterleaved = "strictly_interleaved"
    /// One file holding adjacent mate pairs and unpaired (merged or orphan) reads.
    case mixedMergedAndPairs = "mixed_merged_and_pairs"
    /// Two files, R1 and R2, whose records correspond by position.
    case pairedFiles = "paired_files"

    /// The single-file layout that matches a content classification.
    public init(readLayout: FASTQReadLayout) {
        switch readLayout {
        case .singleEnd: self = .singleEnd
        case .strictlyInterleaved: self = .strictlyInterleaved
        case .mixedInterleaved: self = .mixedMergedAndPairs
        }
    }

    public var displayName: String {
        switch self {
        case .singleEnd: return "single-end"
        case .strictlyInterleaved: return "interleaved pairs"
        case .mixedMergedAndPairs: return "mixed merged reads and pairs"
        case .pairedFiles: return "paired R1/R2 files"
        }
    }

    /// Whether the layout carries mates of paired-end fragments.
    public var holdsPairs: Bool {
        self != .singleEnd
    }
}

// MARK: - FASTQReadLayoutHandling

/// What a tool invocation does with the reads of one ``FASTQInputLayout``.
public enum FASTQReadLayoutHandling: String, Codable, Sendable, CaseIterable, Equatable {
    /// Mates reach the tool as pairs (an interleave flag, R1/R2 arguments, or
    /// a tool that pairs adjacent same-name records on its own).
    case asPairs = "as_pairs"
    /// Every record reaches the tool as an unpaired read.
    case asSingle = "as_single"
    /// The interleaved file is split into temporary R1 and R2 files first.
    case splitToR1R2 = "split_to_r1_r2"

    public var displayName: String {
        switch self {
        case .asPairs: return "as pairs"
        case .asSingle: return "as single reads"
        case .splitToR1R2: return "split into R1/R2"
        }
    }
}

// MARK: - FASTQConsumerDeclaration

/// One FASTQ-consuming tool's declared behaviour for every input layout.
///
/// `handling` must cover every ``FASTQInputLayout`` case; the registry test
/// enforces it. `mixedRationale` says why the mixed layout gets the handling
/// it does, because the contract default for a tool that cannot pair mixed
/// input gracefully is ``FASTQReadLayoutHandling/asSingle``.
public struct FASTQConsumerDeclaration: Sendable, Equatable {
    /// Stable identifier, `<surface>.<tool>` (for example `map.bwa-mem2`).
    public let consumerID: String
    public let displayName: String
    public let handling: [FASTQInputLayout: FASTQReadLayoutHandling]
    public let mixedRationale: String
    /// False when the declared mixed handling pairs records by position
    /// (mates can be misaligned) and is recorded as current behaviour
    /// pending that consumer's own fix.
    public let mixedHandlingIsGraceful: Bool

    public init(
        consumerID: String,
        displayName: String,
        handling: [FASTQInputLayout: FASTQReadLayoutHandling],
        mixedRationale: String,
        mixedHandlingIsGraceful: Bool = true
    ) {
        self.consumerID = consumerID
        self.displayName = displayName
        self.handling = handling
        self.mixedRationale = mixedRationale
        self.mixedHandlingIsGraceful = mixedHandlingIsGraceful
    }

    /// Layouts the declaration leaves out. Empty for a complete declaration.
    public var undeclaredLayouts: [FASTQInputLayout] {
        FASTQInputLayout.allCases.filter { handling[$0] == nil }
    }

    /// The declared handling, falling back to the contract default of single
    /// reads for a layout the declaration omits.
    public func handling(for layout: FASTQInputLayout) -> FASTQReadLayoutHandling {
        handling[layout] ?? .asSingle
    }
}

// MARK: - FASTQInputLayoutResolution

/// The resolved layout of a tool's FASTQ input(s), with where the answer came from.
public struct FASTQInputLayoutResolution: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, Equatable {
        /// The caller stated the layout (a CLI flag).
        case explicit
        /// Two input files bound as R1/R2.
        case pairedFiles = "paired_files"
        /// More than one input file that are not a pair, or no input.
        case pooledFiles = "pooled_files"
        /// The input is not FASTQ (a FASTA of contigs, for example).
        case notFASTQ = "not_fastq"
        /// The enclosing bundle's metadata settled the question on its own.
        case bundleMetadata = "bundle_metadata"
        /// The records were scanned (with bundle metadata as hints).
        case contentScan = "content_scan"
    }

    public let layout: FASTQInputLayout
    public let source: Source
    /// The content classification when the records were scanned.
    public let classification: FASTQReadLayoutClassification?
    /// Plain-language reason for the layout.
    public let reason: String

    public init(
        layout: FASTQInputLayout,
        source: Source,
        classification: FASTQReadLayoutClassification? = nil,
        reason: String
    ) {
        self.layout = layout
        self.source = source
        self.classification = classification
        self.reason = reason
    }
}

// MARK: - FASTQInputLayoutResolver

/// Resolves the ``FASTQInputLayout`` of a tool's input(s), the same way for the
/// GUI, the CLI, and `Copy CLI Command`.
///
/// Order of evidence:
///
/// 1. an explicit layout the caller already knows (a `--read-layout` flag),
/// 2. two files bound as R1/R2 by the caller,
/// 3. the enclosing bundle's metadata: a `singleEnd` pairing the user chose
///    explicitly (`ingestion.pairingSource == explicit`) with no merge
///    evidence settles the question without reading the file. A `singleEnd`
///    that was defaulted, detected, or recorded before `pairingSource` existed
///    does not: imports with no pairing choice recorded `single_end` for files
///    whose records alternate mates, so those are scanned,
/// 4. a bounded scan of the records (``FASTQReadLayoutClassifier``), with the
///    bundle metadata as hints that can demote strict to mixed (a VSP2 merge
///    recipe in the lineage, a read classification with merged reads).
///
/// Mates named identically, with `/1` `/2` suffixes, or with Casava
/// descriptions are all recognised by the scan.
public enum FASTQInputLayoutResolver {

    /// Resolves the layout for the files a tool will read.
    ///
    /// - Parameters:
    ///   - inputURLs: the input file(s) as the tool receives them. A file inside
    ///     a `.lungfishfastq` bundle, or the bundle itself, contributes its
    ///     metadata; a materialized scratch file is scanned on its own.
    ///   - pairedFiles: whether the caller bound exactly two files as R1/R2.
    ///   - explicit: a layout the caller already knows; final when non-nil.
    ///   - recordLimit: how many records the scan reads before deciding.
    public static func resolve(
        inputURLs: [URL],
        pairedFiles: Bool = false,
        explicit: FASTQInputLayout? = nil,
        recordLimit: Int = FASTQReadLayoutClassifier.defaultRecordLimit
    ) -> FASTQInputLayoutResolution {
        if let explicit {
            return FASTQInputLayoutResolution(
                layout: explicit,
                source: .explicit,
                reason: "The caller stated the input is \(explicit.displayName)."
            )
        }
        if pairedFiles, inputURLs.count == 2 {
            return FASTQInputLayoutResolution(
                layout: .pairedFiles,
                source: .pairedFiles,
                reason: "Two input files are bound as R1 and R2."
            )
        }
        guard inputURLs.count == 1, let inputURL = inputURLs.first else {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .pooledFiles,
                reason: inputURLs.isEmpty
                    ? "No input file."
                    : "\(inputURLs.count) input files are pooled as single reads."
            )
        }
        let standardized = inputURL.standardizedFileURL
        if let format = SequenceInputResolver.inputSequenceFormat(for: standardized), format != .fastq {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .notFASTQ,
                reason: "The input is \(format.rawValue.uppercased()), not FASTQ reads."
            )
        }

        let hints = FASTQReadLayoutClassifier.metadataHints(for: standardized)
        if hints.recordsExplicitSingleEnd, !hints.hasMergedOrUnpairedReads {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .bundleMetadata,
                reason: "The bundle metadata records single-end reads, chosen at import."
            )
        }

        let classification = FASTQReadLayoutClassifier.classify(inputURL: standardized, limit: recordLimit)
        return FASTQInputLayoutResolution(
            layout: FASTQInputLayout(readLayout: classification.layout),
            source: .contentScan,
            classification: classification,
            reason: classification.reason
        )
    }

    /// Resolves the layout of a FASTQ that was materialized away from the
    /// bundle whose metadata describes it.
    ///
    /// The GUI hands the CLI and the in-process derivative path a scratch copy
    /// of a bundle's reads; the copy carries no sidecar, so the scan would
    /// lose the bundle's merge evidence (a VSP2 recipe in the lineage). This
    /// entry point scans `fastqURL` with the metadata of `hintURL`, the bundle
    /// or the file inside it, as hints. With no `hintURL` it is
    /// ``resolve(inputURLs:pairedFiles:explicit:recordLimit:)`` on the file.
    public static func resolve(
        fastqURL: URL,
        metadataFrom hintURL: URL?,
        recordLimit: Int = FASTQReadLayoutClassifier.defaultRecordLimit
    ) -> FASTQInputLayoutResolution {
        guard let hintURL else {
            return resolve(inputURLs: [fastqURL], recordLimit: recordLimit)
        }
        let standardized = fastqURL.standardizedFileURL
        if let format = SequenceInputResolver.inputSequenceFormat(for: standardized), format != .fastq {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .notFASTQ,
                reason: "The input is \(format.rawValue.uppercased()), not FASTQ reads."
            )
        }
        let hints = FASTQReadLayoutClassifier.metadataHints(for: hintURL.standardizedFileURL)
        if hints.recordsExplicitSingleEnd, !hints.hasMergedOrUnpairedReads {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .bundleMetadata,
                reason: "The bundle metadata records single-end reads, chosen at import."
            )
        }
        // A bundle directory is scanned through its primary FASTQ, the same
        // file `resolve(inputURLs:)` reads.
        let scanURL = FASTQBundle.isBundleURL(standardized)
            ? (FASTQBundle.resolvePrimaryFASTQURL(for: standardized) ?? standardized)
            : standardized
        let scan = (try? FASTQReadLayoutClassifier.readHeaders(from: scanURL, limit: recordLimit))
            ?? (headers: [], scannedWholeFile: true)
        let classification = FASTQReadLayoutClassifier.classify(
            headers: scan.headers,
            scannedWholeFile: scan.scannedWholeFile,
            metadata: hints
        )
        return FASTQInputLayoutResolution(
            layout: FASTQInputLayout(readLayout: classification.layout),
            source: .contentScan,
            classification: classification,
            reason: classification.reason
        )
    }
}
