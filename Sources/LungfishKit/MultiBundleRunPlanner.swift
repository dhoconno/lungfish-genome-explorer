// MultiBundleRunPlanner.swift - Pure fan-out/pool planning for multi-bundle runs (MB-0)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - MultiBundleRunMode

/// How a tool should handle N>1 selected bundles: run once per bundle, or
/// pool every bundle's inputs into a single combined run.
public enum MultiBundleRunMode: String, CaseIterable, Sendable, Codable {
    /// N runs, N results — each bundle processed independently.
    case perBundle
    /// Pool inputs, 1 run — all bundles combined into a single result.
    case combined
}

// MARK: - MultiBundleRunPolicy

/// Per-tool policy describing which run modes are available and which one
/// is selected by default. Some tools lock the mode entirely (e.g. combining
/// is scientifically wrong for per-sample genotyping) by passing a
/// single-element `allowedModes` set.
public struct MultiBundleRunPolicy: Sendable {
    /// The set of modes the user may choose from. Pass a single-element set
    /// to lock the tool to one mode (the picker then renders the other
    /// option disabled with `lockReason`).
    public var allowedModes: Set<MultiBundleRunMode>

    /// The mode pre-selected when the picker first appears.
    public var defaultMode: MultiBundleRunMode

    /// Explanatory text shown next to a locked-off mode. `nil` when both
    /// modes are allowed.
    public var lockReason: String?

    public init(
        allowedModes: Set<MultiBundleRunMode>,
        defaultMode: MultiBundleRunMode,
        lockReason: String? = nil
    ) {
        self.allowedModes = allowedModes
        self.defaultMode = defaultMode
        self.lockReason = lockReason
    }
}

// MARK: - MultiBundleRunPlanner

/// Pure fan-out/pool planner for running a tool across N>1 bundles.
///
/// `MultiBundleRunPlanner` contains no I/O, no `OperationCenter` calls, and no
/// framework dependencies of its own — it is a plain scheduling algorithm.
/// The App layer supplies `materialize` (composing over the existing
/// `MaterializationPipeline` actor) and `pool` (composing over the existing
/// `FASTQBundleMergeService`) as injected `async` closures, and is
/// responsible for driving `OperationCenter` updates/logs around each
/// resulting group.
///
/// - `perBundle`: each input is materialized independently and returned as
///   its own single-element group, preserving input order. `pool` is never
///   called.
/// - `combined`: all inputs are materialized together in one call, and the
///   materialized result is handed to `pool`, whose output becomes the sole
///   group. Materialization always happens before pooling, so pooling never
///   sees un-materialized (e.g. `preview.fastq`) placeholders.
///
/// Per-child temp cleanup is the responsibility of the injected `materialize`
/// closure itself (each child owns cleanup of its own temporary state on
/// throw/cancel); the planner only propagates the first failure it observes
/// and does not swallow or continue past it.
public struct MultiBundleRunPlanner {

    private init() {}

    /// Plans the group(s) of inputs a tool should run against.
    ///
    /// - Parameters:
    ///   - inputs: The bundles/configs selected by the user, in UI order.
    ///   - mode: `.perBundle` or `.combined`.
    ///   - materialize: App-injected closure that resolves a batch of inputs
    ///     to their fully-materialized form (composing over
    ///     `MaterializationPipeline`). Called once per input in `.perBundle`
    ///     mode (each call receiving a single-element batch), and once with
    ///     all inputs in `.combined` mode.
    ///   - pool: App-injected closure that combines a materialized batch into
    ///     pooled input(s) (composing over `FASTQBundleMergeService`). Only
    ///     invoked in `.combined` mode, and only after `materialize` returns.
    /// - Returns: `.perBundle` → N single-element groups, each materialized,
    ///   in input order. `.combined` → a single pooled group.
    public static func plan<I: Sendable>(
        inputs: [I],
        mode: MultiBundleRunMode,
        materialize: @Sendable ([I]) async throws -> [I],
        pool: @Sendable ([I]) async throws -> [I]
    ) async throws -> [[I]] {
        switch mode {
        case .perBundle:
            var groups: [[I]] = []
            groups.reserveCapacity(inputs.count)
            for input in inputs {
                let materialized = try await materialize([input])
                groups.append(materialized)
            }
            return groups

        case .combined:
            let materialized = try await materialize(inputs)
            let pooled = try await pool(materialized)
            return [pooled]
        }
    }
}
