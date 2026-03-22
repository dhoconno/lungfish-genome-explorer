// DemultiplexPlan.swift - Multi-step demultiplexing plan data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A single step in a multi-step demultiplexing plan.
///
/// Each step uses a specific barcode kit and configuration to demultiplex
/// reads. In a multi-step plan, step 0 runs on the raw input (outer barcodes),
/// step 1 runs on each output bin from step 0 (inner barcodes), and so on.
public struct DemultiplexStep: Codable, Sendable, Equatable, Identifiable {
    /// Unique identifier for this step.
    public let id: UUID

    /// Human-readable label (e.g., "Outer (ONT)", "Inner (PacBio)").
    public var label: String

    /// Which barcode kit to use for this step.
    public var barcodeKitID: String

    /// Where barcodes are located in the reads for this step.
    public var barcodeLocation: BarcodeLocation

    /// How barcode ends relate (symmetric, asymmetric, single-end).
    public var symmetryMode: BarcodeSymmetryMode

    /// Error rate override for this step.
    public var errorRate: Double

    /// Minimum overlap for barcode matching at this step.
    public var minimumOverlap: Int

    /// Whether to search reverse complement (default for long-read platforms).
    public var searchReverseComplement: Bool

    /// Whether to trim barcode sequences from output reads.
    public var trimBarcodes: Bool

    /// Whether to allow indels in barcode matching.
    ///
    /// When true (the default), cutadapt uses edit-distance alignment.
    /// When false, cutadapt uses `--no-indels` (Hamming distance only).
    /// ONT reads have significant indel rates — benchmarking showed allowing
    /// indels improved detection by 18%. Should almost always be true.
    public var allowIndels: Bool

    /// Maximum bases from the 5' end where a barcode may be found (cutadapt adapter distance).
    /// 0 means no constraint (search the full read). Useful for restricting barcode
    /// search to a window near the read ends to prevent amplicon false positives.
    public var maxSearchDistance5Prime: Int

    /// Maximum bases from the 3' end where a barcode may be found.
    /// 0 means no constraint. Same rationale as `maxSearchDistance5Prime`.
    public var maxSearchDistance3Prime: Int

    /// Minimum insert length (bp) between left and right barcode hits.
    /// Used by the exact barcode demux engine for asymmetric kits.
    /// Default: 2000.
    public var minimumInsert: Int

    /// What to do with reads that don't match any barcode.
    public var unassignedDisposition: UnassignedDisposition

    /// Per-step sample assignments (for asymmetric kits at this level).
    public var sampleAssignments: [FASTQSampleBarcodeAssignment]

    /// Zero-indexed ordinal. Step 0 runs first on raw input.
    public var ordinal: Int

    /// The platform that generated the reads being demuxed (may differ from the kit's platform).
    /// When set and different from the kit's platform, the effective error rate is elevated
    /// to account for the source platform's error characteristics.
    public var sourcePlatform: SequencingPlatform?

    public init(
        id: UUID = UUID(),
        label: String,
        barcodeKitID: String,
        barcodeLocation: BarcodeLocation = .bothEnds,
        symmetryMode: BarcodeSymmetryMode = .symmetric,
        errorRate: Double = 0.15,
        minimumOverlap: Int = 20,
        searchReverseComplement: Bool = true,
        trimBarcodes: Bool = true,
        allowIndels: Bool = true,
        maxSearchDistance5Prime: Int = 0,
        maxSearchDistance3Prime: Int = 0,
        minimumInsert: Int = 2000,
        unassignedDisposition: UnassignedDisposition = .keep,
        sampleAssignments: [FASTQSampleBarcodeAssignment] = [],
        ordinal: Int = 0,
        sourcePlatform: SequencingPlatform? = nil
    ) {
        self.id = id
        self.label = label
        self.barcodeKitID = barcodeKitID
        self.barcodeLocation = barcodeLocation
        self.symmetryMode = symmetryMode
        self.errorRate = errorRate
        self.minimumOverlap = minimumOverlap
        self.searchReverseComplement = searchReverseComplement
        self.trimBarcodes = trimBarcodes
        self.allowIndels = allowIndels
        self.maxSearchDistance5Prime = maxSearchDistance5Prime
        self.maxSearchDistance3Prime = maxSearchDistance3Prime
        self.minimumInsert = minimumInsert
        self.unassignedDisposition = unassignedDisposition
        self.sampleAssignments = sampleAssignments
        self.ordinal = ordinal
        self.sourcePlatform = sourcePlatform
    }
}

/// Complete multi-step demultiplexing plan.
///
/// Composes ordered `DemultiplexStep` entries that run sequentially.
/// Step 0 produces N outer bins, step 1 runs independently on each bin, etc.
///
/// ```
/// Step 0: ONT outer barcodes -> BC01/, BC02/, ...
/// Step 1: PacBio inner barcodes -> BC01/bc1003--bc1016/, BC01/bc1008/, ...
/// ```
public struct DemultiplexPlan: Codable, Sendable, Equatable {
    /// Ordered steps. Step 0 is outermost.
    public var steps: [DemultiplexStep]

    /// Maps composite barcode paths to user-assigned sample names.
    /// Key: composite path like "BC01/bc1003--bc1016"
    /// Value: user-assigned sample name like "Patient-042"
    public var compositeSampleNames: [String: String]

    public init(
        steps: [DemultiplexStep] = [],
        compositeSampleNames: [String: String] = [:]
    ) {
        self.steps = steps
        self.compositeSampleNames = compositeSampleNames
    }

    /// Whether this is a single-step plan (the common case).
    public var isSingleStep: Bool { steps.count <= 1 }

    /// Validates the plan for execution.
    public func validate() throws {
        guard !steps.isEmpty else {
            throw DemultiplexPlanError.noSteps
        }
        for step in steps {
            if step.barcodeKitID.isEmpty {
                throw DemultiplexPlanError.missingKit(step: step.label)
            }
        }
        // Check for duplicate ordinals
        let ordinals = steps.map(\.ordinal)
        let uniqueOrdinals = Set(ordinals)
        if uniqueOrdinals.count != ordinals.count {
            throw DemultiplexPlanError.duplicateOrdinals
        }
    }
}

/// Result of a multi-step demultiplexing pipeline run.
public struct MultiStepDemultiplexResult: Sendable {
    /// Per-step results.
    public let stepResults: [StepResult]

    /// Final output bundles (leaf-level, fully demultiplexed).
    public let outputBundleURLs: [URL]

    /// Composite manifest combining all steps.
    public let manifest: DemultiplexManifest

    /// Total wall clock time in seconds.
    public let wallClockSeconds: Double

    /// Result for one step across all its input bins.
    public struct StepResult: Sendable {
        public let step: DemultiplexStep
        public let perBinResults: [DemultiplexResult]
        /// Per-bin failures (bins that failed are excluded from perBinResults).
        public let binFailures: [BinFailure]
        /// Wall clock time for this step in seconds.
        public let wallClockSeconds: Double

        public init(step: DemultiplexStep, perBinResults: [DemultiplexResult], binFailures: [BinFailure] = [], wallClockSeconds: Double = 0) {
            self.step = step
            self.perBinResults = perBinResults
            self.binFailures = binFailures
            self.wallClockSeconds = wallClockSeconds
        }
    }

    /// Records a bin that failed during a multi-step demux.
    public struct BinFailure: Sendable {
        /// Name of the input bin that failed.
        public let binName: String
        /// Error description.
        public let errorDescription: String
    }
}

/// Errors related to demultiplexing plan validation.
public enum DemultiplexPlanError: Error, LocalizedError, Sendable {
    case noSteps
    case missingKit(step: String)
    case duplicateOrdinals

    public var errorDescription: String? {
        switch self {
        case .noSteps:
            return "Demultiplexing plan has no steps."
        case .missingKit(let step):
            return "Step '\(step)' has no barcode kit selected."
        case .duplicateOrdinals:
            return "Demultiplexing plan has steps with duplicate ordinals."
        }
    }
}
