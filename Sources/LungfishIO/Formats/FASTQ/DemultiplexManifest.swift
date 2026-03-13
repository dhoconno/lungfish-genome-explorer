// DemultiplexManifest.swift - Metadata for demultiplexing operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "DemultiplexManifest")

// MARK: - Demultiplex Manifest

/// Manifest stored in the multiplexed parent bundle after demultiplexing.
///
/// Records the full demux configuration, barcode assignments, and links to
/// per-barcode output bundles. Lives at `demux-manifest.json` inside the
/// parent `.lungfishfastq` bundle.
///
/// ```
/// multiplexed.lungfishfastq/
///   reads.fastq.gz
///   demux-manifest.json          <-- this file
///   demux/                       <-- child directory
///     bc01-SampleA.lungfishfastq/
///     bc02-SampleB.lungfishfastq/
///     unassigned.lungfishfastq/
/// ```
public struct DemultiplexManifest: Codable, Sendable, Equatable {
    public static let filename = "demux-manifest.json"

    /// Schema version for forward compatibility.
    public let version: Int

    /// Unique identifier for this demux run (used for invalidation on re-demux).
    public let runID: UUID

    /// Date the demultiplexing was performed.
    public let demultiplexedAt: Date

    /// Barcode kit identification.
    public let barcodeKit: BarcodeKit

    /// Parameters used for demultiplexing.
    public let parameters: DemultiplexParameters

    /// Per-barcode results.
    public let barcodes: [BarcodeResult]

    /// Unassigned reads summary.
    public let unassigned: UnassignedReadsSummary

    /// Relative path from the parent bundle to the demux output directory.
    /// Convention: `"demux/"` (child directory inside the bundle).
    public let outputDirectoryRelativePath: String

    /// Total input read count before demultiplexing.
    public let inputReadCount: Int

    /// Multi-step provenance (nil for single-step demux runs).
    public let multiStepProvenance: MultiStepProvenance?

    /// Total read count across all barcodes plus unassigned.
    public var totalOutputReadCount: Int {
        barcodes.reduce(0) { $0 + $1.readCount } + unassigned.readCount
    }

    /// Total assigned read count (excluding unassigned).
    public var assignedReadCount: Int {
        barcodes.reduce(0) { $0 + $1.readCount }
    }

    /// Assignment rate as a fraction (0.0-1.0).
    public var assignmentRate: Double {
        guard inputReadCount > 0 else { return 0 }
        return Double(assignedReadCount) / Double(inputReadCount)
    }

    /// Whether the accounting balances (all reads accounted for).
    public var isAccountingBalanced: Bool {
        inputReadCount == totalOutputReadCount
    }

    public init(
        version: Int = 1,
        runID: UUID = UUID(),
        demultiplexedAt: Date = Date(),
        barcodeKit: BarcodeKit,
        parameters: DemultiplexParameters,
        barcodes: [BarcodeResult],
        unassigned: UnassignedReadsSummary,
        outputDirectoryRelativePath: String,
        inputReadCount: Int,
        multiStepProvenance: MultiStepProvenance? = nil
    ) {
        self.version = version
        self.runID = runID
        self.demultiplexedAt = demultiplexedAt
        self.barcodeKit = barcodeKit
        self.parameters = parameters
        self.barcodes = barcodes
        self.unassigned = unassigned
        self.outputDirectoryRelativePath = outputDirectoryRelativePath
        self.inputReadCount = inputReadCount
        self.multiStepProvenance = multiStepProvenance
    }

    // MARK: - Persistence

    /// Loads the demux manifest from a parent bundle, if present.
    public static func load(from bundleURL: URL) -> DemultiplexManifest? {
        let url = bundleURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DemultiplexManifest.self, from: data)
        } catch {
            logger.warning("Failed to load demux manifest: \(error)")
            return nil
        }
    }

    /// Saves the demux manifest to a parent bundle.
    public func save(to bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Returns true if the given bundle contains a demux manifest.
    public static func isDemultiplexedBundle(_ bundleURL: URL) -> Bool {
        let url = bundleURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Barcode Kit

/// Barcode kit identification.
public struct BarcodeKit: Codable, Sendable, Equatable {
    /// Kit name (e.g., "SQK-NBD114.96", "TruSeq Single Index").
    public let name: String

    /// Vendor/platform (e.g., "oxford_nanopore", "pacbio", "illumina", "custom").
    public let vendor: String

    /// Number of barcodes defined in the kit.
    public let barcodeCount: Int

    /// Whether this kit uses dual indexing (i5 + i7 for Illumina).
    public let isDualIndexed: Bool

    /// Barcode type: symmetric (same both ends), asymmetric (different each end),
    /// or singleEnd (barcode on one end only, e.g., ONT rapid).
    public let barcodeType: BarcodeType

    public init(
        name: String,
        vendor: String,
        barcodeCount: Int,
        isDualIndexed: Bool = false,
        barcodeType: BarcodeType = .symmetric
    ) {
        self.name = name
        self.vendor = vendor
        self.barcodeCount = barcodeCount
        self.isDualIndexed = isDualIndexed
        self.barcodeType = barcodeType
    }
}

/// Barcode placement type.
public enum BarcodeType: String, Codable, Sendable, CaseIterable {
    /// Same barcode on both ends (ONT native, PacBio symmetric).
    case symmetric
    /// Different barcodes on each end (PacBio asymmetric, Illumina dual-index).
    case asymmetric
    /// Barcode on one end only (ONT rapid barcoding).
    case singleEnd
}

// MARK: - Demultiplex Parameters

/// Parameters controlling the demultiplexing algorithm.
public struct DemultiplexParameters: Codable, Sendable, Equatable {
    /// Tool used (e.g., "dorado", "lima", "cutadapt", "demuxbyname.sh").
    public let tool: String

    /// Tool version string.
    public let toolVersion: String?

    /// Maximum allowed mismatches in barcode sequence.
    public let maxMismatches: Int

    /// Minimum barcode score threshold (dorado/lima use this).
    public let minScore: Double?

    /// Whether to require barcodes on both ends of the read.
    public let requireBothEnds: Bool

    /// Whether to trim barcode sequences from output reads.
    public let trimBarcodes: Bool

    /// Raw command line used for full reproducibility.
    public let commandLine: String?

    /// Wall clock time for the demux operation in seconds.
    public let wallClockSeconds: Double?

    public init(
        tool: String,
        toolVersion: String? = nil,
        maxMismatches: Int = 1,
        minScore: Double? = nil,
        requireBothEnds: Bool = false,
        trimBarcodes: Bool = true,
        commandLine: String? = nil,
        wallClockSeconds: Double? = nil
    ) {
        self.tool = tool
        self.toolVersion = toolVersion
        self.maxMismatches = maxMismatches
        self.minScore = minScore
        self.requireBothEnds = requireBothEnds
        self.trimBarcodes = trimBarcodes
        self.commandLine = commandLine
        self.wallClockSeconds = wallClockSeconds
    }
}

// MARK: - Barcode Result

/// Per-barcode demultiplexing result.
public struct BarcodeResult: Codable, Sendable, Equatable, Identifiable {
    /// Barcode identifier (e.g., "barcode01", "N701").
    public let barcodeID: String

    /// User-assigned sample name (e.g., "Patient-042").
    public var sampleName: String?

    /// Forward barcode sequence.
    public let forwardSequence: String?

    /// Reverse barcode sequence (for dual-indexed Illumina).
    public let reverseSequence: String?

    /// Number of reads assigned to this barcode.
    public let readCount: Int

    /// Number of bases assigned to this barcode.
    public let baseCount: Int64

    /// Mean quality score for reads in this barcode.
    public let meanQuality: Double?

    /// Mean read length for this barcode.
    public let meanReadLength: Double?

    /// Relative path from the demux output directory to this barcode's bundle.
    public let bundleRelativePath: String

    public var id: String { barcodeID }

    /// Display name: sample name if set, otherwise barcode ID.
    public var displayName: String {
        sampleName ?? barcodeID
    }

    public init(
        barcodeID: String,
        sampleName: String? = nil,
        forwardSequence: String? = nil,
        reverseSequence: String? = nil,
        readCount: Int,
        baseCount: Int64,
        meanQuality: Double? = nil,
        meanReadLength: Double? = nil,
        bundleRelativePath: String
    ) {
        self.barcodeID = barcodeID
        self.sampleName = sampleName
        self.forwardSequence = forwardSequence
        self.reverseSequence = reverseSequence
        self.readCount = readCount
        self.baseCount = baseCount
        self.meanQuality = meanQuality
        self.meanReadLength = meanReadLength
        self.bundleRelativePath = bundleRelativePath
    }
}

// MARK: - Unassigned Reads

/// Summary for reads that could not be assigned to any barcode.
public struct UnassignedReadsSummary: Codable, Sendable, Equatable {
    /// Number of unassigned reads.
    public let readCount: Int

    /// Number of unassigned bases.
    public let baseCount: Int64

    /// How unassigned reads are handled.
    public let disposition: UnassignedDisposition

    /// Relative path to the unassigned reads bundle (nil if discarded).
    public let bundleRelativePath: String?

    public init(
        readCount: Int,
        baseCount: Int64,
        disposition: UnassignedDisposition = .keep,
        bundleRelativePath: String? = nil
    ) {
        self.readCount = readCount
        self.baseCount = baseCount
        self.disposition = disposition
        self.bundleRelativePath = bundleRelativePath
    }
}

/// What to do with reads that fail barcode assignment.
public enum UnassignedDisposition: String, Codable, Sendable, CaseIterable {
    /// Keep in a separate "unassigned" bundle.
    case keep
    /// Discard entirely (not written to disk).
    case discard
}

// MARK: - Multi-Step Provenance

/// Provenance record for multi-step demultiplexing runs.
///
/// Captures the full plan, per-step kit/parameter summaries, and composite
/// sample name mappings. Stored in the composite manifest so the user can
/// reconstruct exactly what happened at each level.
public struct MultiStepProvenance: Codable, Sendable, Equatable {
    /// Total number of steps in the plan.
    public let totalSteps: Int

    /// Per-step summaries recording kit, symmetry, and error rate.
    public let stepSummaries: [StepSummary]

    /// Composite barcode path → user-assigned sample name.
    /// Key: "BC01/bc1003--bc1016", Value: "Patient-042"
    public let compositeSampleNames: [String: String]

    /// Total wall clock time across all steps in seconds.
    public let totalWallClockSeconds: Double

    public init(
        totalSteps: Int,
        stepSummaries: [StepSummary],
        compositeSampleNames: [String: String] = [:],
        totalWallClockSeconds: Double = 0
    ) {
        self.totalSteps = totalSteps
        self.stepSummaries = stepSummaries
        self.compositeSampleNames = compositeSampleNames
        self.totalWallClockSeconds = totalWallClockSeconds
    }

    /// Summary of a single step in the plan.
    public struct StepSummary: Codable, Sendable, Equatable {
        /// Step label (e.g., "Outer (ONT)").
        public let label: String
        /// Barcode kit ID used at this step.
        public let barcodeKitID: String
        /// Symmetry mode used at this step.
        public let symmetryMode: BarcodeSymmetryMode
        /// Error rate used at this step.
        public let errorRate: Double
        /// Number of input bins processed at this step.
        public let inputBinCount: Int
        /// Number of output bundles produced at this step.
        public let outputBundleCount: Int
        /// Total reads processed at this step.
        public let totalReadsProcessed: Int
        /// Wall clock time for this step in seconds.
        public let wallClockSeconds: Double

        public init(
            label: String,
            barcodeKitID: String,
            symmetryMode: BarcodeSymmetryMode,
            errorRate: Double,
            inputBinCount: Int,
            outputBundleCount: Int,
            totalReadsProcessed: Int,
            wallClockSeconds: Double
        ) {
            self.label = label
            self.barcodeKitID = barcodeKitID
            self.symmetryMode = symmetryMode
            self.errorRate = errorRate
            self.inputBinCount = inputBinCount
            self.outputBundleCount = outputBundleCount
            self.totalReadsProcessed = totalReadsProcessed
            self.wallClockSeconds = wallClockSeconds
        }
    }
}
