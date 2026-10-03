// PlatformLabelCheck.swift - Finds FASTQ bundles whose recorded platform contradicts the reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Compares the platform a FASTQ sidecar records with what the reads show.
///
/// Bundles imported before platform inference may carry a wrong label, most
/// often Illumina on Oxford Nanopore or PacBio reads. Nothing is rewritten. A
/// suspect label is reported so the Inspector, the mapping and assembly
/// windows and `lungfish-cli fastq platform --check` can show it, and a person
/// decides. A bundle whose sidecar has a ``PlatformAssignment`` is never
/// suspect, because its label was inferred, given, corrected or confirmed.
public struct PlatformLabelCheck: Sendable, Equatable {

    public enum Verdict: String, Sendable, Equatable {
        /// The label agrees with the reads, or the reads give no strong evidence.
        case consistent
        /// The label contradicts high-confidence evidence or the read lengths.
        case suspect
        /// The bundle records how its label was decided, so it is not questioned.
        case decided
        /// No label was recorded.
        case unlabelled
    }

    public let verdict: Verdict
    public let recordedPlatform: SequencingPlatform?
    public let recordedReadClass: FASTQAssemblyReadType?
    public let inference: PlatformInference?
    /// Sentences that explain a suspect verdict.
    public let reasons: [String]

    public var isSuspect: Bool { verdict == .suspect }

    /// The platform the evidence points to when the label is suspect.
    public var suggestedPlatform: SequencingPlatform? {
        guard isSuspect, let inference, inference.isActionable else { return nil }
        return inference.platform
    }

    /// Checks the FASTQ behind a bundle, a file inside a bundle or a plain file.
    public static func check(inputURL: URL) -> PlatformLabelCheck? {
        let standardized = inputURL.standardizedFileURL
        guard let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: standardized)
            ?? FASTQBundle.resolvePrimaryFASTQURL(for: standardized.deletingLastPathComponent()) else {
            return nil
        }
        return check(fastqURL: fastqURL, metadata: FASTQMetadataStore.load(for: fastqURL))
    }

    /// Checks one FASTQ file against its sidecar metadata.
    public static func check(
        fastqURL: URL,
        metadata: PersistedFASTQMetadata?,
        inference suppliedInference: PlatformInference? = nil
    ) -> PlatformLabelCheck {
        let platform = metadata?.sequencingPlatform
        let readClass = metadata?.assemblyReadType
        if metadata?.platformAssignment != nil {
            return PlatformLabelCheck(
                verdict: .decided, recordedPlatform: platform, recordedReadClass: readClass,
                inference: nil, reasons: []
            )
        }
        guard platform != nil || readClass != nil else {
            return PlatformLabelCheck(
                verdict: .unlabelled, recordedPlatform: nil, recordedReadClass: nil,
                inference: nil, reasons: []
            )
        }

        var reasons: [String] = []
        let maxLength = metadata?.computedStatistics?.maxReadLength ?? 0
        if readClass == .illuminaShortReads, maxLength > 1_000 {
            reasons.append("The bundle is recorded as short reads, but its longest read is \(PlatformInference.formatted(maxLength)) bases.")
        }

        let inference = suppliedInference ?? PlatformInference.infer(fromFASTQ: fastqURL)
        if inference.confidence == .high, inference.platform != .unknown {
            let recordedName = platform?.displayName ?? "no platform"
            if let platform, platform != inference.platform {
                reasons.append("Recorded as \(recordedName), but the read headers look like \(inference.platform.displayName). \(inference.evidence.first ?? "")")
            } else if let readClass, let inferredClass = inference.readClass, readClass != inferredClass {
                reasons.append("Recorded as \(readClass.displayName), but the reads look like \(inferredClass.displayName). \(inference.evidence.first ?? "")")
            }
        }

        return PlatformLabelCheck(
            verdict: reasons.isEmpty ? .consistent : .suspect,
            recordedPlatform: platform,
            recordedReadClass: readClass,
            inference: inference,
            reasons: reasons.map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }
}
