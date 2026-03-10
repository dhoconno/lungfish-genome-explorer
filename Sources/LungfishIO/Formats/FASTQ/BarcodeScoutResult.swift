// BarcodeScoutResult.swift - Barcode detection scouting data model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Result of scanning a subset of reads to detect which barcodes are present.
///
/// The scout pipeline runs cutadapt against a sample of reads (default 10,000)
/// with all barcodes in the selected kit(s). Results are presented to the user
/// for review before full demultiplexing.
public struct BarcodeScoutResult: Codable, Sendable {
    /// Total reads scanned in the scout run.
    public let readsScanned: Int

    /// Per-barcode detection results, sorted by hit count descending.
    public var detections: [BarcodeDetection]

    /// Number of reads that matched no barcode.
    public let unassignedCount: Int

    /// Kit ID(s) used for scouting.
    public let scoutedKitIDs: [String]

    /// Wall clock time for the scout run in seconds.
    public let elapsedSeconds: Double

    public init(
        readsScanned: Int,
        detections: [BarcodeDetection],
        unassignedCount: Int,
        scoutedKitIDs: [String],
        elapsedSeconds: Double
    ) {
        self.readsScanned = readsScanned
        self.detections = detections
        self.unassignedCount = unassignedCount
        self.scoutedKitIDs = scoutedKitIDs
        self.elapsedSeconds = elapsedSeconds
    }

    /// Percentage of reads that were assigned to any barcode.
    public var assignmentRate: Double {
        guard readsScanned > 0 else { return 0 }
        return Double(readsScanned - unassignedCount) / Double(readsScanned)
    }

    /// Number of barcodes that were accepted by the user.
    public var acceptedCount: Int {
        detections.filter { $0.disposition == .accepted }.count
    }

    /// Accepted detections only.
    public var acceptedDetections: [BarcodeDetection] {
        detections.filter { $0.disposition == .accepted }
    }

    /// Filename for persisting scout results in the bundle.
    public static let filename = "scout-result.json"
}

/// Detection result for a single barcode during scouting.
public struct BarcodeDetection: Codable, Sendable, Identifiable {
    public let id: UUID

    /// Barcode ID from the kit (e.g., "BC01", "D701").
    public let barcodeID: String

    /// Kit ID this barcode belongs to.
    public let kitID: String

    /// Number of reads matching this barcode.
    public let hitCount: Int

    /// Percentage of total scanned reads.
    public var hitPercentage: Double

    /// Which read end(s) matched.
    public let matchedEnds: MatchedEnds

    /// Mean edit distance of matches (lower = more confident).
    public let meanEditDistance: Double?

    /// User's disposition: accept, reject, or undecided.
    public var disposition: DetectionDisposition

    /// User-assigned sample name (populated during review).
    public var sampleName: String?

    public init(
        id: UUID = UUID(),
        barcodeID: String,
        kitID: String,
        hitCount: Int,
        hitPercentage: Double,
        matchedEnds: MatchedEnds = .unknown,
        meanEditDistance: Double? = nil,
        disposition: DetectionDisposition = .undecided,
        sampleName: String? = nil
    ) {
        self.id = id
        self.barcodeID = barcodeID
        self.kitID = kitID
        self.hitCount = hitCount
        self.hitPercentage = hitPercentage
        self.matchedEnds = matchedEnds
        self.meanEditDistance = meanEditDistance
        self.disposition = disposition
        self.sampleName = sampleName
    }
}

/// User's disposition for a detected barcode.
public enum DetectionDisposition: String, Codable, Sendable {
    case accepted
    case rejected
    case undecided
}

/// Which end(s) of the read a barcode was found on.
public enum MatchedEnds: String, Codable, Sendable {
    case fivePrimeOnly
    case threePrimeOnly
    case bothEnds
    case unknown
}

/// How barcode ends relate to each other in a demux run.
public enum BarcodeSymmetryMode: String, Codable, Sendable, CaseIterable {
    /// Same barcode expected on both ends (ONT native, PacBio symmetric).
    case symmetric
    /// Different barcodes on each end (PacBio asymmetric, custom).
    case asymmetric
    /// Barcode on one end only (ONT rapid, some Illumina).
    case singleEnd
}
