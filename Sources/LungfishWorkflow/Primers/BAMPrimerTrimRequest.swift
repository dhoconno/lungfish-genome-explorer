// BAMPrimerTrimRequest.swift - Inputs to the BAM primer-trim pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Inputs required to run the BAM primer-trim pipeline.
///
/// Bundles the source BAM, the resolved primer-scheme bundle, and the desired
/// output location, along with iVar-compatible trimming parameters whose
/// defaults match `ivar trim`'s documented defaults. Consumed by the
/// `BAMPrimerTrimPipeline` to produce a primer-trimmed, coordinate-sorted,
/// indexed BAM.
public struct BAMPrimerTrimRequest: Sendable {
    /// URL of the source BAM file to be primer-trimmed.
    public let sourceBAMURL: URL

    /// The primer-scheme bundle providing the BED file of primer coordinates.
    public let primerSchemeBundle: PrimerSchemeBundle

    /// Desired URL for the trimmed, coordinate-sorted output BAM.
    public let outputBAMURL: URL

    /// Minimum length (bp) for a read to be retained after trimming.
    public let minReadLength: Int

    /// Minimum Phred quality threshold for iVar's sliding-window quality trim.
    public let minQuality: Int

    /// Sliding-window width (bp) used by iVar for the quality trim.
    public let slidingWindow: Int

    /// Offset (bp) applied to primer coordinates when matching reads.
    public let primerOffset: Int

    /// Reproducible top-level command or workflow invocation that initiated the run.
    public let workflowCommand: [String]

    /// Creates a request with explicit URLs and iVar-compatible defaults.
    /// - Parameters:
    ///   - sourceBAMURL: URL of the source BAM to be trimmed.
    ///   - primerSchemeBundle: Loaded primer-scheme bundle whose BED is used for trimming.
    ///   - outputBAMURL: Desired URL for the trimmed, coordinate-sorted output BAM.
    ///   - minReadLength: Minimum read length (bp) to retain; defaults to 30.
    ///   - minQuality: Minimum Phred quality for the sliding-window trim; defaults to 20.
    ///   - slidingWindow: Sliding-window width (bp); defaults to 4.
    ///   - primerOffset: Primer coordinate offset (bp); defaults to 0.
    ///   - workflowCommand: Reproducible top-level command or workflow invocation.
    public init(
        sourceBAMURL: URL,
        primerSchemeBundle: PrimerSchemeBundle,
        outputBAMURL: URL,
        minReadLength: Int = 30,
        minQuality: Int = 20,
        slidingWindow: Int = 4,
        primerOffset: Int = 0,
        workflowCommand: [String] = []
    ) {
        self.sourceBAMURL = sourceBAMURL
        self.primerSchemeBundle = primerSchemeBundle
        self.outputBAMURL = outputBAMURL
        self.minReadLength = minReadLength
        self.minQuality = minQuality
        self.slidingWindow = slidingWindow
        self.primerOffset = primerOffset
        self.workflowCommand = workflowCommand
    }
}
