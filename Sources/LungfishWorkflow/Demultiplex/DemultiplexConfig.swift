// DemultiplexConfig.swift - Configuration for a cutadapt-based demultiplexing run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

// MARK: - Demultiplex Configuration

/// Configuration for a cutadapt-based demultiplexing run.
public struct DemultiplexConfig: Sendable {
    /// Input FASTQ file URL (may be inside a .lungfishfastq bundle or standalone).
    public let inputURL: URL

    /// Logical source bundle for lineage propagation and parent-manifest links.
    ///
    /// This may differ from `inputURL` when demultiplexing operates on a temporary
    /// materialized FASTQ derived from an existing bundle.
    public let sourceBundleURL: URL?

    /// Barcode kit definition (built-in or custom).
    public let barcodeKit: BarcodeKitDefinition

    /// Output directory for per-barcode .lungfishfastq bundles.
    public let outputDirectory: URL

    /// Where barcodes are located in the reads.
    public let barcodeLocation: BarcodeLocation

    /// How barcode ends relate (symmetric, asymmetric, single-end).
    /// Defaults from kit's pairing mode but can be overridden.
    public let symmetryMode: BarcodeSymmetryMode

    /// Maximum error rate for barcode matching (cutadapt -e).
    /// Defaults from platform's recommended rate.
    public let errorRate: Double

    /// Minimum overlap between barcode and read (cutadapt --overlap).
    /// Defaults from platform's recommended overlap.
    public let minimumOverlap: Int

    /// Maximum bases from the 5' terminus where a barcode may begin.
    public let maxDistanceFrom5Prime: Int

    /// Maximum bases from the 3' terminus where a barcode may end.
    public let maxDistanceFrom3Prime: Int

    /// Whether to trim barcode sequences from output reads.
    public let trimBarcodes: Bool

    /// Whether to search both strand orientations (--revcomp).
    /// Defaults to true for long-read platforms (ONT, PacBio).
    public let searchReverseComplement: Bool

    /// What to do with reads that don't match any barcode.
    public let unassignedDisposition: UnassignedDisposition

    /// Poly-G trim quality threshold for two-color SBS platforms (cutadapt --nextseq-trim=N).
    ///
    /// Set to a quality score (e.g. 20) to enable poly-G trimming, or nil to disable.
    /// Defaults from platform: Illumina/Element = 20, others = nil (disabled).
    public let polyGTrimQuality: Int?

    /// Number of threads for cutadapt (--cores).
    public let threads: Int

    /// Optional adapter context override.
    ///
    /// When nil (the default), the adapter context is derived from the kit's
    /// platform and kit type. Set this to override the default context for
    /// custom adapter constructs.
    public let adapterContext: (any PlatformAdapterContext)?

    /// Backend engine used for demultiplexing.
    public let engine: DemultiplexEngine

    /// Optional explicit asymmetric sample assignments.
    ///
    /// When present, these are used to build linked 5'/3' adapters directly,
    /// avoiding cartesian expansion for combinatorial kits.
    public let sampleAssignments: [FASTQSampleBarcodeAssignment]

    /// The platform that generated the FASTQ reads (may differ from the barcode kit's platform).
    /// When set and different from the kit's platform, the effective error rate is
    /// max(config.errorRate, sourcePlatform.recommendedErrorRate).
    public var sourcePlatform: LungfishIO.SequencingPlatform?

    /// Root bundle URL for writing derived manifests in virtual demux bundles.
    /// When set, each per-barcode bundle will contain a derived-manifest.json
    /// pointing back to this root for on-demand materialization.
    public let rootBundleURL: URL?

    /// Root FASTQ filename inside the root bundle (e.g., "reads.fastq.gz").
    public let rootFASTQFilename: String?

    /// Pairing mode of the logical input dataset.
    ///
    /// When nil, the pipeline infers pairing from `sourceBundleURL`/`inputURL`.
    public let inputPairingMode: IngestionMetadata.PairingMode?

    /// Sequence format of the logical input dataset when virtual demux
    /// manifests should materialize back to FASTA.
    public let inputSequenceFormat: SequenceFormat?

    /// Resolved adapter context (uses override if set, otherwise derives from kit).
    public var resolvedAdapterContext: any PlatformAdapterContext {
        adapterContext ?? barcodeKit.adapterContext
    }

    /// Effective error rate accounting for cross-platform scenarios.
    ///
    /// When the source platform differs from the kit's platform (e.g., PacBio kit on ONT reads),
    /// uses the higher of the configured error rate and the source platform's recommended rate.
    public var effectiveErrorRate: Double {
        guard let sourcePlatform, sourcePlatform != barcodeKit.platform else {
            return errorRate
        }
        return max(errorRate, sourcePlatform.recommendedErrorRate)
    }

    /// Effective minimum overlap accounting for cross-platform scenarios.
    ///
    /// For long-read platforms with short barcodes (e.g., 16bp PacBio barcodes on ONT),
    /// a high overlap threshold relative to barcode length is overly strict.
    /// Caps overlap at barcode_length - 4 to allow partial boundary matches.
    public var effectiveMinimumOverlap: Int {
        let minBarcodeLen = barcodeKit.barcodes.reduce(Int.max) { currentMin, barcode in
            let i7Len = barcode.i7Sequence.count
            let i5Len = barcode.i5Sequence?.count ?? i7Len
            return min(currentMin, min(i7Len, i5Len))
        }
        let barcodeLen = minBarcodeLen == Int.max ? 16 : minBarcodeLen
        // Don't require more than barcode_length - 4 overlap
        return min(minimumOverlap, max(3, barcodeLen - 4))
    }

    /// Minimum insert length (bp) between left and right barcode hits.
    /// Used by the exact barcode demux engine for asymmetric kits.
    /// Default: 2000.
    public let minimumInsert: Int

    /// Whether to disallow indels in barcode matching (cutadapt --no-indels).
    ///
    /// Defaults to `false` (indels allowed). ONT reads have significant indel
    /// rates even in barcode regions — benchmarking showed that allowing indels
    /// improved detection by 18% (50→59 both-end reads on 100-read test set).
    public let useNoIndels: Bool

    /// When true, capture per-read trim positions even in full mode so that
    /// downstream inner steps can chain trim offsets back to the root FASTQ.
    /// Set by multi-step pipelines for non-final steps.
    public let captureTrimsForChaining: Bool

    public init(
        inputURL: URL,
        sourceBundleURL: URL? = nil,
        barcodeKit: BarcodeKitDefinition,
        outputDirectory: URL,
        barcodeLocation: BarcodeLocation = .bothEnds,
        symmetryMode: BarcodeSymmetryMode? = nil,
        errorRate: Double? = nil,
        minimumOverlap: Int? = nil,
        maxDistanceFrom5Prime: Int = 0,
        maxDistanceFrom3Prime: Int = 0,
        trimBarcodes: Bool = true,
        searchReverseComplement: Bool? = nil,
        unassignedDisposition: UnassignedDisposition = .keep,
        polyGTrimQuality: Int? = nil,
        threads: Int = 4,
        adapterContext: (any PlatformAdapterContext)? = nil,
        engine: DemultiplexEngine = .cutadapt,
        sampleAssignments: [FASTQSampleBarcodeAssignment] = [],
        sourcePlatform: LungfishIO.SequencingPlatform? = nil,
        rootBundleURL: URL? = nil,
        rootFASTQFilename: String? = nil,
        inputPairingMode: IngestionMetadata.PairingMode? = nil,
        inputSequenceFormat: SequenceFormat? = nil,
        minimumInsert: Int = 2000,
        useNoIndels: Bool = false,
        captureTrimsForChaining: Bool = false
    ) {
        self.inputURL = inputURL
        if let sourceBundleURL {
            self.sourceBundleURL = sourceBundleURL
        } else if FASTQBundle.isBundleURL(inputURL) {
            self.sourceBundleURL = inputURL
        } else {
            self.sourceBundleURL = nil
        }
        self.barcodeKit = barcodeKit
        self.outputDirectory = outputDirectory
        self.barcodeLocation = barcodeLocation

        // Default symmetry from kit pairing mode
        self.symmetryMode = symmetryMode ?? {
            switch barcodeKit.pairingMode {
            case .singleEnd: return .singleEnd
            case .symmetric: return .symmetric
            case .fixedDual: return .asymmetric
            case .combinatorialDual: return .asymmetric
            }
        }()

        // Default error rate and overlap from platform
        self.errorRate = errorRate ?? barcodeKit.platform.recommendedErrorRate
        self.minimumOverlap = minimumOverlap ?? barcodeKit.platform.recommendedMinimumOverlap

        self.maxDistanceFrom5Prime = max(0, maxDistanceFrom5Prime)
        self.maxDistanceFrom3Prime = max(0, maxDistanceFrom3Prime)
        self.trimBarcodes = trimBarcodes
        self.adapterContext = adapterContext
        self.searchReverseComplement = searchReverseComplement
            ?? barcodeKit.platform.readsCanBeReverseComplemented
        self.unassignedDisposition = unassignedDisposition
        // Default poly-G trimming from platform (nil for non-two-color platforms)
        self.polyGTrimQuality = polyGTrimQuality ?? barcodeKit.platform.defaultPolyGTrimQuality
        self.threads = threads
        self.sampleAssignments = sampleAssignments
        self.engine = engine
        self.sourcePlatform = sourcePlatform
        self.rootBundleURL = rootBundleURL
        self.rootFASTQFilename = rootFASTQFilename
        self.inputPairingMode = inputPairingMode
        self.inputSequenceFormat = inputSequenceFormat
        self.minimumInsert = minimumInsert
        self.useNoIndels = useNoIndels
        self.captureTrimsForChaining = captureTrimsForChaining
    }
}
