// ClassifierExtractionError.swift - Errors produced by ClassifierReadResolver
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

// MARK: - ClassifierExtractionError

/// Errors produced by `ClassifierReadResolver`.
///
/// Distinct from the lower-level `ExtractionError` so callers can differentiate
/// resolver-scoped failures (BAM-not-found-for-sample, missing Kraken2 output,
/// etc.) from primitive samtools/seqkit failures.
public enum ClassifierExtractionError: Error, LocalizedError, Sendable {

    /// The requested tool does not expose BAM-backed reads.
    case unsupportedBAMTool(ClassifierTool)

    /// No BAM file could be found for the given sample ID.
    case bamNotFound(sampleId: String)

    /// The BAM of the given sample is a link to a file outside the result folder. The resolver never reads
    /// it, so the user is told the true cause in place of "not found" (decision W4 of 2.9).
    case bamOutsideResult(sampleId: String)

    /// The Kraken2 per-read classified output file was missing or unreadable.
    case kraken2OutputMissing(URL)

    /// The Kraken2 taxonomy tree could not be loaded from disk.
    case kraken2TreeMissing(URL)

    /// The Kraken2 source FASTQ is in neither the project that holds the result nor where the run recorded it.
    /// The words say to put the read bundle back into the project or classify again there, and the Extract
    /// alert, the BLAST alert and the CLI all show them (W4-COPY-SOURCE).
    case kraken2SourceMissing

    /// A per-sample samtools invocation failed.
    case samtoolsFailed(sampleId: String, stderr: String)

    /// An extracted clipboard payload exceeded the requested cap.
    case clipboardCapExceeded(requested: Int, cap: Int)

    /// Destination directory not writable.
    case destinationNotWritable(URL)

    /// FASTQ → FASTA conversion failed while reading an input record.
    case fastaConversionFailed(String)

    /// A single invocation mixed selectors for a direct result with batch-sample selectors.
    case mixedSampleSelectionModes

    /// Zero reads were extracted despite a non-empty pre-flight estimate.
    case zeroReadsExtracted

    /// Every selected sample was skipped because its classification sidecar or
    /// source FASTQ could not be resolved.
    case allSamplesSkipped([String])

    /// The underlying extraction was cancelled.
    case cancelled

    /// A clipboard or share destination reached the resolver, which writes only a file or a bundle. Those
    /// rows run `lungfish-cli extract reads --by-classifier` and copy the file it writes (Phase 2.12 lane
    /// 12.11). The words are the ones the command prints for the same refusal.
    case unsupportedCopyDestination

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .unsupportedBAMTool(let tool):
            return "\(tool.displayName) does not expose BAM-backed reads. Use the classifier extraction path for \(tool.displayName) instead."
        case .bamNotFound(let sampleId):
            return "No BAM file found for sample '\(sampleId)'. The classifier result may be corrupted or imported without the underlying alignment data."
        case .bamOutsideResult(let sampleId):
            return "The BAM file of sample '\(sampleId)' is a link to a file outside this result folder, and LGE extracts reads only from BAM files inside it. Replace the link with a copy of the file and try again."
        case .kraken2OutputMissing(let url):
            return "Kraken2 per-read classification output not found: \(url.lastPathComponent)"
        case .kraken2TreeMissing(let url):
            return "Kraken2 taxonomy tree not found: \(url.lastPathComponent)"
        case .kraken2SourceMissing:
            return "The FASTQ reads this Kraken2 result was made from are missing. "
                + "They are not in this project or where the run recorded them. "
                + "Put their bundle back into this project and try again, "
                + "or run the classification again in this project."
        case .samtoolsFailed(let sampleId, let stderr):
            return "samtools view failed for sample '\(sampleId)': \(stderr)"
        case .clipboardCapExceeded(let requested, let cap):
            return "Selection contains \(requested) reads, which exceeds the clipboard cap of \(cap). Choose Save to File, Save as Bundle, or Share instead."
        case .destinationNotWritable(let url):
            return "Destination is not writable: \(url.path)"
        case .fastaConversionFailed(let reason):
            return "FASTQ → FASTA conversion failed: \(reason)"
        case .mixedSampleSelectionModes:
            return "Cannot combine single-sample and batch-sample selections in one extraction."
        case .zeroReadsExtracted:
            return "The selection produced zero reads. Try adjusting the flag filter or selecting different rows."
        case .allSamplesSkipped(let samples):
            return "No reads could be extracted: \(samples.count) sample(s) were skipped because their classification output or source FASTQ could not be located (\(samples.joined(separator: ", ")))."
        case .cancelled:
            return "Extraction was cancelled"
        case .unsupportedCopyDestination:
            return "Clipboard / share destinations are not supported from the CLI"
        }
    }

    /// Whether the error is a refusal that the extraction itself would hit again, so a pre-flight estimate that
    /// ends in it leaves nothing to run. True for exactly the two BAM refusals (Phase 2.12 lane 12.26, U-W2).
    public var blocksExtraction: Bool {
        switch self {
        case .bamNotFound, .bamOutsideResult:
            return true
        default:
            return false
        }
    }
}
