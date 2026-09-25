// EsVirituDiagnostics.swift - Read-length gate and failure-reason extraction for EsViritu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - Read lengths

/// Read-length summary for one EsViritu sample, taken from persisted
/// FASTQ statistics (or, as a last resort, a prefix sample of the reads).
public struct EsVirituReadLengths: Sendable, Equatable {
    /// Longest read in the input, in bases.
    public let maxReadLength: Int?
    /// Median read length, in bases. `nil` when only a summary without a
    /// median (for example `seqkit stats`) is available.
    public let medianReadLength: Int?

    public init(maxReadLength: Int?, medianReadLength: Int?) {
        self.maxReadLength = maxReadLength
        self.medianReadLength = medianReadLength
    }

    /// Reads the persisted statistics for the given input files (FASTQ files
    /// or `.lungfishfastq` bundles) without streaming any reads.
    ///
    /// Sources, in order: bundle-level `.lungfish-meta.json` (multi-file
    /// bundles), a derived bundle's cached statistics, then the FASTQ file's
    /// own `.lungfish-meta.json` sidecar (`computedStatistics`, then
    /// `seqkitStats`). Multiple files (R1/R2) are combined by taking the
    /// largest value, so a warning only fires when every file is short.
    ///
    /// - Returns: `nil` when no input has persisted statistics.
    public static func persisted(for inputURLs: [URL]) -> EsVirituReadLengths? {
        var maxValues: [Int] = []
        var medianValues: [Int] = []
        for url in inputURLs {
            guard let lengths = persisted(forSingle: url) else { continue }
            if let max = lengths.maxReadLength { maxValues.append(max) }
            if let median = lengths.medianReadLength { medianValues.append(median) }
        }
        guard !maxValues.isEmpty || !medianValues.isEmpty else { return nil }
        return EsVirituReadLengths(
            maxReadLength: maxValues.max(),
            medianReadLength: medianValues.max()
        )
    }

    /// Persisted lengths, falling back to the longest read in the first
    /// 32 KB of each input when no statistics have been saved.
    public static func persistedOrSampled(for inputURLs: [URL]) -> EsVirituReadLengths? {
        if let persisted = persisted(for: inputURLs), persisted.maxReadLength != nil {
            return persisted
        }
        guard let sampledMax = MappingInputInspection.inspect(urls: inputURLs).observedMaxReadLength else {
            return nil
        }
        return EsVirituReadLengths(maxReadLength: sampledMax, medianReadLength: nil)
    }

    private static func persisted(forSingle url: URL) -> EsVirituReadLengths? {
        let fm = FileManager.default
        var candidates: [(statistics: FASTQDatasetStatistics?, seqkit: SeqkitStatsMetadata?)] = []

        var bundleURL: URL?
        if FASTQBundle.isBundleURL(url) {
            bundleURL = url
        } else if FASTQBundle.isBundleURL(url.deletingLastPathComponent()) {
            bundleURL = url.deletingLastPathComponent()
        }

        if let bundleURL {
            if let meta = FASTQMetadataStore.load(for: bundleURL) {
                candidates.append((meta.computedStatistics, meta.seqkitStats))
            }
            if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                candidates.append((manifest.cachedStatistics, nil))
            }
        }

        let fastqURL = FASTQBundle.isBundleURL(url) ? FASTQBundle.resolvePrimaryFASTQURL(for: url) : url
        if let fastqURL, fm.fileExists(atPath: FASTQMetadataStore.metadataURL(for: fastqURL).path),
           let meta = FASTQMetadataStore.load(for: fastqURL) {
            candidates.append((meta.computedStatistics, meta.seqkitStats))
        }

        for candidate in candidates {
            if let stats = candidate.statistics, stats.readCount > 0, stats.maxReadLength > 0 {
                return EsVirituReadLengths(
                    maxReadLength: stats.maxReadLength,
                    medianReadLength: stats.medianReadLength > 0 ? stats.medianReadLength : nil
                )
            }
        }
        for candidate in candidates {
            if let seqkit = candidate.seqkit, seqkit.numSeqs > 0, seqkit.maxLen > 0 {
                return EsVirituReadLengths(maxReadLength: seqkit.maxLen, medianReadLength: nil)
            }
        }
        return nil
    }
}

// MARK: - Read-length advisory

/// Warns when reads are too short for EsViritu's alignment filter.
///
/// EsViritu 1.3.x (`esv_funcs.py`, `minimap2_f`) keeps only alignments with
/// `alignLength >= 100`, `alignProp >= 0.9` and `alignAcc >= 0.8`. Reads
/// shorter than 100 bases can never pass, so a 2x76 bp NextSeq run yields
/// "No reads aligned to the EsViritu DB" and no detection table.
public enum EsVirituReadLengthAdvisory: Sendable, Equatable {
    /// Every read is shorter than the minimum alignment length.
    case allReadsTooShort(maxReadLength: Int)
    /// At least half the reads are shorter than the minimum alignment length.
    case mostReadsTooShort(medianReadLength: Int, maxReadLength: Int?)

    /// EsViritu's hard-coded minimum alignment length, in bases.
    public static let minimumAlignmentLength = 100

    /// Evaluates read lengths against EsViritu's minimum alignment length.
    public static func evaluate(_ lengths: EsVirituReadLengths?) -> EsVirituReadLengthAdvisory? {
        guard let lengths else { return nil }
        if let max = lengths.maxReadLength, max > 0, max < minimumAlignmentLength {
            return .allReadsTooShort(maxReadLength: max)
        }
        if let median = lengths.medianReadLength, median > 0, median < minimumAlignmentLength {
            return .mostReadsTooShort(medianReadLength: median, maxReadLength: lengths.maxReadLength)
        }
        return nil
    }

    /// Evaluates the persisted statistics of the given input files.
    public static func evaluate(inputURLs: [URL]) -> EsVirituReadLengthAdvisory? {
        evaluate(EsVirituReadLengths.persisted(for: inputURLs))
    }

    /// `true` for the strong (every read too short) case.
    public var isSevere: Bool {
        if case .allReadsTooShort = self { return true }
        return false
    }

    /// Text shown in the EsViritu dialog before Run.
    public var wizardMessage: String {
        let minimum = Self.minimumAlignmentLength
        switch self {
        case .allReadsTooShort(let max):
            return "The longest read in this dataset is \(max) bases. EsViritu ignores alignments shorter than \(minimum) bases, so it will likely report no viruses for these reads. Kraken 2 works with reads of this length."
        case .mostReadsTooShort(let median, _):
            return "The median read length in this dataset is \(median) bases. EsViritu ignores alignments shorter than \(minimum) bases, so reads below that length cannot count toward a detection."
        }
    }

    /// Hint appended to a failed EsViritu run.
    public var failureHint: String {
        let minimum = Self.minimumAlignmentLength
        switch self {
        case .allReadsTooShort(let max):
            return "The longest input read is \(max) bases. EsViritu ignores alignments shorter than \(minimum) bases, so these reads cannot produce a detection."
        case .mostReadsTooShort(let median, _):
            return "The median input read length is \(median) bases. EsViritu ignores alignments shorter than \(minimum) bases, so most of these reads cannot produce a detection."
        }
    }
}

// MARK: - Failure diagnosis

/// What EsViritu itself said when a run ended without a detection table.
public struct EsVirituFailureDiagnosis: Sendable, Equatable {
    /// The message of the last `ERROR` (or `CRITICAL`) line in EsViritu's
    /// log, with the timestamp and level stripped.
    public let reportedError: String?
    /// Short-read hint, when the input reads are too short for EsViritu.
    public let readLengthHint: String?
    /// The last lines of EsViritu's log, for the Operations failure report.
    public let logTail: String?

    public init(reportedError: String?, readLengthHint: String?, logTail: String?) {
        self.reportedError = reportedError
        self.readLengthHint = readLengthHint
        self.logTail = logTail
    }

    /// Extracts the message of the last ERROR/CRITICAL line from EsViritu
    /// log text (either `<sample>_esviritu.log` or the colorized stderr).
    ///
    /// EsViritu logs with `'%(asctime)s - %(levelname)s - %(message)s'`, so a
    /// line looks like
    /// `2026-09-24 10:01:02,345 - ERROR - No reads aligned to the EsViritu DB in x.bam. Exiting...`.
    public static func lastReportedError(inLog text: String) -> String? {
        var last: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripANSI(rawLine)
            for marker in [" - ERROR - ", " - CRITICAL - "] {
                if let range = line.range(of: marker) {
                    let message = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !message.isEmpty { last = message }
                    break
                }
            }
        }
        return last
    }

    /// Returns the last `count` non-empty lines of the log, ANSI-stripped.
    public static func tail(ofLog text: String, count: Int = 20) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map(stripANSI)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Builds a diagnosis from the EsViritu log file (preferred) or stderr.
    public static func diagnose(
        logURL: URL,
        stderr: String,
        readLengths: EsVirituReadLengths?
    ) -> EsVirituFailureDiagnosis {
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let reported = lastReportedError(inLog: logText) ?? lastReportedError(inLog: stderr)
        let tailSource = logText.isEmpty ? stderr : logText
        return EsVirituFailureDiagnosis(
            reportedError: reported,
            readLengthHint: EsVirituReadLengthAdvisory.evaluate(readLengths)?.failureHint,
            logTail: tail(ofLog: tailSource)
        )
    }

    private static func stripANSI(_ line: String) -> String {
        line.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}
