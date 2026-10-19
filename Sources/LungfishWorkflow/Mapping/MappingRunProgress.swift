// MappingRunProgress.swift - The words and fractions a Map Reads run reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The steps a Map Reads run shows, shared by the window's in-process route and
/// `lungfish-cli map --format json`, so the row reads the same on either route (Phase 2.10
/// lane A46, ruling 1 of its M1 review).
///
/// Each step is a fraction for the bar and the words for the row's detail, and both routes log
/// the words at info once. The in-process route shows a step on its row, and `map` writes it as a
/// `progress` event that the app's bridge shows the same way. The callbacks that give the steps
/// are the input resolver's, `ManagedMappingPipeline`'s and the viewer publication's of
/// ``MappingResultLayoutService``.
public enum MappingRunProgress {
    /// One step of a run.
    public struct Step: Sendable, Equatable {
        /// Where the bar stands, from 0 to 1.
        public let fraction: Double
        /// The row's detail, and the line the log keeps.
        public let message: String

        public init(fraction: Double, message: String) {
            self.fraction = fraction
            self.message = message
        }
    }

    /// Where the viewer bundle's steps start.
    static let viewerStart = 0.93
    /// The share of the bar the viewer bundle's steps take.
    static let viewerShare = 0.06

    /// The row's first detail, and the message of `map`'s `start` line, for `inputCount` inputs
    /// as given and the reference as given.
    public static func startDetail(inputCount: Int, reference: URL) -> String {
        "Mapping \(inputCount) file(s) to \(reference.lastPathComponent)"
    }

    /// A message of the input resolver, such as a virtual bundle being materialized, at 0.
    public static func resolving(_ message: String) -> Step {
        Step(fraction: 0, message: message)
    }

    /// A step of the mapping pipeline, at the pipeline's own fraction.
    public static func mapping(_ fraction: Double, _ message: String) -> Step {
        Step(fraction: fraction, message: message)
    }

    /// The step before the reference viewer bundle is published, shown only when the reference is inside a .lungfishref bundle.
    public static let preparingViewer = Step(fraction: viewerStart, message: "Preparing reference mapping viewer...")

    /// A step of the viewer bundle's publication, from 0.93 to 0.99.
    public static func publishingViewer(_ fraction: Double, _ message: String) -> Step {
        Step(fraction: viewerStart + fraction * viewerShare, message: message)
    }

    /// The info line that names the read layout a run maps with and why, logged once the inputs
    /// are resolved.
    public static func readLayoutLine(for request: MappingRunRequest, reason: String) -> String {
        let plan = request.readLayoutPlan
        return "Read layout: \(plan.layout.displayName), mapped \(plan.handling.displayName) (\(reason))"
    }

    /// The row's completion detail, which is also the message of `map`'s `complete` line.
    public static func completionDetail(mappedReads: Int, totalReads: Int) -> String {
        "Mapping complete: \(mappedReads)/\(totalReads) reads mapped"
    }
}
