// DemultiplexResult.swift - Result of a demultiplexing pipeline run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

// MARK: - Demultiplex Result

/// Result of a demultiplexing pipeline run.
public struct DemultiplexResult: Sendable {
    /// Generated demultiplex manifest.
    public let manifest: DemultiplexManifest

    /// URLs of created per-barcode .lungfishfastq bundles.
    public let outputBundleURLs: [URL]

    /// URL of the unassigned reads bundle (nil if discarded or empty).
    public let unassignedBundleURL: URL?

    /// Wall clock time in seconds.
    public let wallClockSeconds: Double

    /// Exact native argv used for the primary demultiplexing tool, when the run
    /// uses an external native tool.
    public let nativeCommand: [String]?

    /// BIO's chance floor of a search of the bare bases, with the barcodes at or below it (L5), or nil when the
    /// run's search does not take the floor.
    public var chanceFloor: DemultiplexChanceFloor.Outcome? = nil

    /// The engine that ran, which the route owner chose when the run named none, or nil for the asymmetric search.
    public var engine: DemultiplexEngine? = nil

    /// The way the first reads carry the secondary sequence of a custom dual-index definition at Both Ends with no sample
    /// sheet, and the votes that chose it (DEMUX-DUAL-FORM), or nil on every other route.
    public var secondaryForm: DemultiplexingPipeline.SecondaryFormChoice? = nil

    /// The placed reads that two or more rows fit at their fewest errors, which went to Unassigned, on the route of
    /// `secondaryForm` with a 5' or 3' Distance above 0 (DEMUX-DUAL-OFFSET-SHIFT), or nil on every other run.
    public var ambiguousReads: Int? = nil
}
