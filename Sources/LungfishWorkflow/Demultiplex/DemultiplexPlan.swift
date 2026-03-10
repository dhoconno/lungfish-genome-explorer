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

    /// What to do with reads that don't match any barcode.
    public var unassignedDisposition: UnassignedDisposition

    /// Per-step sample assignments (for asymmetric kits at this level).
    public var sampleAssignments: [FASTQSampleBarcodeAssignment]

    /// Zero-indexed ordinal. Step 0 runs first on raw input.
    public var ordinal: Int

    public init(
        id: UUID = UUID(),
        label: String,
        barcodeKitID: String,
        barcodeLocation: BarcodeLocation = .bothEnds,
        symmetryMode: BarcodeSymmetryMode = .symmetric,
        errorRate: Double = 0.15,
        minimumOverlap: Int = 3,
        searchReverseComplement: Bool = true,
        trimBarcodes: Bool = true,
        unassignedDisposition: UnassignedDisposition = .keep,
        sampleAssignments: [FASTQSampleBarcodeAssignment] = [],
        ordinal: Int = 0
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
        self.unassignedDisposition = unassignedDisposition
        self.sampleAssignments = sampleAssignments
        self.ordinal = ordinal
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
        /// Wall clock time for this step in seconds.
        public let wallClockSeconds: Double

        public init(step: DemultiplexStep, perBinResults: [DemultiplexResult], wallClockSeconds: Double = 0) {
            self.step = step
            self.perBinResults = perBinResults
            self.wallClockSeconds = wallClockSeconds
        }
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
