// AnalysisRunTool.swift - The protocol an analysis tool implements to run under the analysis run executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A tool that runs one analysis command under the analysis run executor, such as Kraken2 or
/// EsViritu.
///
/// The executor owns the lifecycle of the run and calls the tool in a fixed order. A tool never
/// creates, settles or discards the analysis folder and never writes the root record.
///
/// 1. ``plan(_:context:)`` (phase P0) validates the request, resolves what the run needs, groups
///    samples into units and plans read sets. It writes nothing, so a refused request leaves no
///    folder behind.
/// 2. ``run(_:context:)`` (P2) runs one unit in the folder the executor made for it and writes the
///    unit's outputs and its own record there. The executor runs units one at a time, in plan
///    order, and checks for a cancel request between them. In a one-folder layout or a shared batch
///    root the unit's folder is the result folder, and the root record written in P4 replaces any
///    record the unit wrote there. So a unit hands each fact of its record to the root record
///    through the context's `recordInput`, `recordStep` and `recordOptions` as soon as it has it,
///    as the Kraken2 wrapper record keeps the pipeline's steps today.
/// 3. ``finalize(_:context:)`` (P3) writes the run-level artifacts, such as a summary, a batch
///    manifest and the viewer index, after every unit and before the executor writes the root
///    record. It runs only when the units leave the run completed.
///
/// ``terminalPolicy`` says how the outcomes of the units end the run.
public protocol AnalysisRunTool: Sendable {
    /// One run of the tool, such as one sample's configuration. A unit may hold several samples
    /// when the tool runs them in one process.
    associatedtype Unit: Sendable
    /// What a completed unit hands to ``finalize(_:context:)``.
    associatedtype UnitResult: Sendable

    /// The analysis kind and the record name of the command.
    var identity: AnalysisRunIdentity { get }

    /// How the unit outcomes end the run. The default fails the run at the first failed unit.
    var terminalPolicy: AnalysisRunTerminalPolicy { get }

    /// The share of the run's progress that ``finalize(_:context:)`` owns at the end of the bar, at
    /// least 0 and less than 1 (W3 of Phase 2.9). The units move the bar from 0 to `1 - share` and the
    /// finalize from there to 1, so a finalize that builds a viewer index, as TaxTriage's does after
    /// its Nextflow run, does not sit at the end of the bar. The default 0 gives the units the whole
    /// bar, as Kraken2 and EsViritu have always had it.
    var finalizeProgressShare: Double { get }

    /// Phase P0. Turns the request into units without writing anything.
    ///
    /// Every check that refuses a request without running a tool belongs here, such as the
    /// options, the inputs and their read layout, the database and its digest, and an input inside
    /// an output the run would remove. A refused request then leaves a named folder and any record
    /// in it as they were. A thrown error refuses the request. The run fails before any folder exists, and its
    /// command exits with the code the error carries (``AnalysisRunExitCoding``), else with
    /// ``AnalysisRunExitCode/workflowError``.
    func plan(
        _ request: AnalysisRunRequest,
        context: AnalysisRunPlanningContext
    ) async throws -> AnalysisRunPlan<Unit>

    /// Phase P2. Runs one unit. A thrown error ends the unit as failed with the error's
    /// description. A thrown error or a failed outcome while a cancel is requested ends the whole
    /// run as cancelled, whatever the error or the reason says, because a unit whose child the
    /// cancel signalled fails before or after its task sees the cancel (SWIFT X2).
    ///
    /// A refusal here is a failed unit. The run's failed root record replaces any record a named
    /// folder already held, so refuse in ``plan(_:context:)`` whatever can be refused before a
    /// tool runs.
    func run(
        _ unit: AnalysisRunUnit<Unit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<UnitResult>

    /// Phase P3. Writes the run-level artifacts and says what the root record and the last event
    /// hold. A thrown error fails the run.
    func finalize(
        _ units: [AnalysisUnitReport<UnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization
}

extension AnalysisRunTool {
    public var terminalPolicy: AnalysisRunTerminalPolicy { .failOnAnyFailedUnit }

    public var finalizeProgressShare: Double { 0 }
}

/// What kind of analysis a tool runs and the name its root record is written under.
public struct AnalysisRunIdentity: Sendable, Equatable {
    /// The analysis kind. It names the folder `Analyses/<tool>-<timestamp>/` and the `tool` of
    /// `analysis-metadata.json`, and it keys the viewer index builder.
    public let toolID: AnalysisToolID
    /// The workflow name of the root record, such as `lungfish.classify`.
    public let workflowName: String

    public init(toolID: AnalysisToolID, workflowName: String) {
        self.toolID = toolID
        self.workflowName = workflowName
    }

    /// The name the registry gives the analysis kind, used in run records and messages.
    public var displayName: String {
        AnalysisToolRegistry.displayName(forRawID: toolID.rawValue)
    }
}

/// How a run's result folder holds its units (E2).
public enum AnalysisRunLayout: String, Sendable, Equatable, CaseIterable {
    /// The unit writes into the result folder itself, as a plain `--output` run of one sample
    /// does today. The root record replaces any record the unit wrote there, so a unit hands its
    /// record's facts to the root record through its context. The layout holds exactly one unit,
    /// which may hold several samples, and the executor refuses a plan with more before any folder
    /// exists.
    case singleFolder
    /// The result folder is a batch root. Each unit gets its own folder, named after its label
    /// through the one sanitizer `AnalysesFolder.batchSampleDirectory(named:in:)`, and a
    /// `--project` run's folder is named `<tool>-batch-<timestamp>`.
    case batchRoot
    /// The result folder is a batch root that every unit writes into directly, for an engine that
    /// runs several samples in one process, such as TaxTriage. A `--project` run's folder is named
    /// `<tool>-batch-<timestamp>` and its `analysis-metadata.json` says batch. Otherwise the
    /// executor treats it as ``singleFolder``, so each unit gets the result folder itself and the
    /// root record replaces any record a unit wrote there. Unlike ``singleFolder`` it may hold
    /// several units, each writing files of its own.
    case sharedBatchRoot
}
