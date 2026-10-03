// AssemblyReadType.swift - Read-class model for the shared assembly surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Visible read classes supported by the v1 assembly experience.
public enum AssemblyReadType: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    /// Human-readable display name shown in the shared assembly UI.
    public var displayName: String {
        switch self {
        case .illuminaShortReads: return "Illumina short reads"
        case .ontReads: return "ONT reads"
        case .pacBioHiFi: return "PacBio HiFi/CCS"
        }
    }

    /// Short explanation of the expected input class.
    public var detail: String {
        switch self {
        case .illuminaShortReads:
            return "Single-end or paired-end short reads from Illumina-style data."
        case .ontReads:
            return "Single-file Oxford Nanopore long reads."
        case .pacBioHiFi:
            return "Single-file PacBio HiFi/CCS long reads."
        }
    }

    /// Maps sequencing-platform detection onto the supported v1 assembly classes.
    public static func detect(from platform: LungfishIO.SequencingPlatform) -> Self? {
        switch platform {
        case .illumina, .element, .mgi: return .illuminaShortReads
        case .oxfordNanopore: return .ontReads
        case .pacbio: return nil
        default: return nil
        }
    }

    /// Maps the workflow-level ingestion platform model onto v1 assembly classes.
    public static func detect(fromWorkflowPlatform platform: IngestionPlatform) -> Self? {
        switch platform {
        case .illumina: return .illuminaShortReads
        case .ont: return .ontReads
        case .pacbio: return nil
        default: return nil
        }
    }

    /// Best-effort FASTQ-based read-type detection with the shared platform
    /// detector. PacBio reads count as HiFi only with CCS or HiFi evidence.
    public static func detect(fromFASTQ url: URL) -> Self? {
        detect(fromInference: PlatformInference.infer(fromFASTQ: url))
    }

    /// The assembly read type of an inference, nil unless it names a platform.
    public static func detect(fromInference inference: PlatformInference) -> Self? {
        guard inference.isActionable else { return nil }
        return inference.readClass.flatMap(Self.init(persistedReadType:))
    }

    /// The read type an input of unknown platform defaults to, from its read
    /// lengths. Only a default, never a gate.
    public static func lengthDefault(forInputURL url: URL) -> Self? {
        guard let fastqURL = resolveFASTQURL(forInputURL: url) else { return nil }
        return PlatformInference.defaultReadType(forLengthProfile: PlatformInference.lengthProfile(forFASTQ: fastqURL))
            .flatMap(Self.init(persistedReadType:))
    }

    /// Best-effort detection for an app-selected assembly input.
    ///
    /// Supports raw FASTQ files, `.lungfishfastq` bundles, and files inside bundles.
    /// Falls back to persisted sequencing-platform metadata when header sniffing
    /// is inconclusive.
    public static func detect(fromInputURL url: URL) -> Self? {
        guard let fastqURL = resolveFASTQURL(forInputURL: url) else {
            return nil
        }

        let persistedMetadata = FASTQMetadataStore.load(for: fastqURL)

        if let explicitReadType = persistedMetadata?.assemblyReadType.flatMap(Self.init(persistedReadType:)) {
            return explicitReadType
        }

        if let detected = detect(fromFASTQ: fastqURL) {
            return detected
        }

        if let platform = persistedMetadata?.sequencingPlatform {
            return detect(from: platform)
        }

        return nil
    }

    /// Best-effort multi-input detection, preserving stable case order.
    public static func detectAll(fromFASTQs urls: [URL]) -> [Self] {
        let detected = Set(urls.compactMap(detect(fromFASTQ:)))
        return allCases.filter { detected.contains($0) }
    }

    /// Stable CLI spelling for the shared assembly surface.
    public var cliArgument: String {
        switch self {
        case .illuminaShortReads:
            return "illumina-short-reads"
        case .ontReads:
            return "ont-reads"
        case .pacBioHiFi:
            return "pacbio-hifi"
        }
    }

    /// Parses the CLI spelling used by the app and CLI entry points.
    public init?(cliArgument: String) {
        switch cliArgument {
        case "illumina-short-reads":
            self = .illuminaShortReads
        case "ont-reads":
            self = .ontReads
        case "pacbio-hifi":
            self = .pacBioHiFi
        default:
            return nil
        }
    }

    public init?(persistedReadType: FASTQAssemblyReadType) {
        switch persistedReadType {
        case .illuminaShortReads:
            self = .illuminaShortReads
        case .ontReads:
            self = .ontReads
        case .pacBioHiFi:
            self = .pacBioHiFi
        }
    }

    /// Header-based detection with the shared platform detector.
    public static func detect(fromFASTQHeader header: String) -> Self? {
        detect(fromInference: PlatformInference.infer(fromHeader: header))
    }

    /// Resolves the FASTQ payload behind an app-selected input (raw file,
    /// bundle, or a file inside a bundle). Shared with the Flye profile selector.
    static func resolveFASTQURL(forInputURL url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: standardizedURL) {
            return resolved
        }

        let parentURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        return FASTQBundle.resolvePrimaryFASTQURL(for: parentURL)
    }
}
