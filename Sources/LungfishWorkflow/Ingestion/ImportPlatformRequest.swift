// ImportPlatformRequest.swift - The `import fastq --platform` value and how a sample's platform is resolved
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// What `lungfish-cli import fastq --platform` asked for.
///
/// `auto` (the default) infers the platform of each sample from its reads with
/// ``PlatformInference``. Any other value is a platform the user gave, recorded
/// as given even when the reads suggest another one. Nothing defaults to
/// Illumina. Reads whose platform cannot be inferred are recorded as Unknown.
public enum ImportPlatformRequest: Sendable, Equatable {
    case auto
    case given(LungfishIO.SequencingPlatform)

    /// Every value `--platform` accepts, in the order the help lists them.
    public static let cliValues = ["auto", "illumina", "ont", "pacbio", "element", "mgi", "ultima", "unknown"]

    /// Parses a `--platform` value. Accepts `auto`, the values above, the
    /// LungfishIO raw values and the vendor aliases of `SequencingPlatform(vendor:)`
    /// (such as `nanopore` and `oxford-nanopore`). Returns nil for anything else.
    public init?(cliValue: String) {
        let normalized = cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "auto" {
            self = .auto
            return
        }
        if normalized == "unknown" {
            self = .given(.unknown)
            return
        }
        let platform = LungfishIO.SequencingPlatform(vendor: normalized)
        guard platform != .unknown else { return nil }
        self = .given(platform)
    }

    /// The value written back on a command line.
    public var cliValue: String {
        switch self {
        case .auto: return "auto"
        case .given(let platform): return platform.importCLIValue
        }
    }
}

extension LungfishIO.SequencingPlatform {
    /// The `import fastq --platform` spelling of this platform. Oxford Nanopore
    /// is `ont` here and `oxfordNanopore` in sidecars.
    public var importCLIValue: String {
        switch self {
        case .illumina: return "illumina"
        case .oxfordNanopore: return "ont"
        case .pacbio: return "pacbio"
        case .element: return "element"
        case .ultima: return "ultima"
        case .mgi: return "mgi"
        case .unknown: return "unknown"
        }
    }

    /// Whether imports of this platform reorder reads with clumpify for
    /// storage by default. Short-read platforms only. Unknown reorders only
    /// when the import asks, and long reads never do.
    public var supportsStorageClumping: Bool {
        switch self {
        case .illumina, .element, .mgi, .ultima: return true
        case .oxfordNanopore, .pacbio, .unknown: return false
        }
    }
}

/// The platform one sample is imported as, how it was decided, and the evidence.
public struct ImportPlatformResolution: Sendable, Equatable {
    public let platform: LungfishIO.SequencingPlatform
    public let readClass: FASTQAssemblyReadType?
    public let source: PlatformAssignment.Source
    public let inference: PlatformInference
    /// Set when a given platform contradicts high-confidence evidence.
    public let contradiction: String?

    /// The sidecar record of this decision.
    public func assignment(recordedAt: Date = Date()) -> PlatformAssignment {
        PlatformAssignment(
            source: source,
            platform: platform,
            readClass: readClass,
            vendorDetail: inference.vendorDetail,
            confidence: inference.confidence,
            evidence: inference.evidence,
            sampledRecords: inference.sampledRecords,
            detectorVersion: PlatformInference.detectorVersion,
            recordedAt: recordedAt
        )
    }

    /// One line for the CLI and the Operations panel.
    public var summaryLine: String {
        let readClassText = readClass.map { ", \($0.displayName)" } ?? ""
        switch source {
        case .inferred where platform == .unknown:
            return "Platform: Unknown. \(inference.evidence.joined(separator: " ")) The bundle is recorded as Unknown, so mapping and assembly choose defaults from read length that are not tuned to a platform. Set the platform with --platform or with lungfish-cli fastq platform <bundle> --set <platform>."
        case .inferred:
            return "Platform: \(platform.displayName)\(readClassText) (inferred, \(inference.confidence.rawValue) confidence). Evidence: \(inference.evidence.joined(separator: " ")) Pass --platform to override."
        default:
            return "Platform: \(platform.displayName)\(readClassText) (given with --platform)."
        }
    }
}

extension FASTQBatchImporter {

    /// Infers the platform of one sample from its first read file. A BAM file
    /// is read from its header. R2 is not read, because mates share a platform.
    public static func inferPlatform(for pair: SamplePair) -> PlatformInference {
        if SequencingReadImportSource.isBAM(pair.r1) {
            return PlatformInference.infer(fromBAM: pair.r1)
        }
        return PlatformInference.infer(fromFASTQ: pair.r1)
    }

    /// Resolves the platform of one sample for a `--platform` request.
    public static func resolvePlatform(
        for pair: SamplePair,
        request: ImportPlatformRequest
    ) -> ImportPlatformResolution {
        let inference = inferPlatform(for: pair)
        switch request {
        case .auto:
            return ImportPlatformResolution(
                platform: inference.isActionable ? inference.platform : .unknown,
                readClass: inference.isActionable ? inference.readClass : nil,
                source: .inferred,
                inference: inference,
                contradiction: nil
            )
        case .given(let platform):
            var readClass = FASTQAssemblyReadType(sequencingPlatform: platform)
            if inference.isActionable, inference.platform == platform, let inferredClass = inference.readClass {
                readClass = inferredClass
            }
            var contradiction: String?
            if inference.confidence == .high, inference.isActionable, inference.platform != platform {
                contradiction = "--platform \(platform.importCLIValue) was given, but the reads look like \(inference.platform.displayName). \(inference.evidence.first ?? "") The given platform is used."
            }
            return ImportPlatformResolution(
                platform: platform,
                readClass: readClass,
                source: .given,
                inference: inference,
                contradiction: contradiction
            )
        }
    }
}
