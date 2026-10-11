// ProvenanceRecorder+Observation.swift - Declared steps whose ToolProcess launch the recorder observes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import Synchronization
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ProvenanceRecorder")

/// A step that a pipeline declares before its tool launches, so the ToolProcess observation of that
/// launch reaches the step's record (`docs/contracts/RECORDING-PROVENANCE.md`, "The ToolProcess
/// observer hook").
///
/// The adapter that launches the step binds ``observer`` around its one launch of the step and around
/// no other launch, so a version probe or a help call through the same adapter is never observed.
///
/// ```swift
/// let declaration = await recorder.declareStep(runID: runID)
/// let result = try await ToolProcessObservation.$observer.withValue(declaration?.observer) {
///     try await ToolProcess.run(spec)
/// }
/// let stepID = await recorder.recordStep(runID: runID, ..., exitCode: result.status, ...)
/// if let declaration {
///     await recorder.recordObservation(of: declaration, forStep: stepID)
/// }
/// ```
///
/// The observer runs on the run's queue before anything waiting on the run wakes, so it only appends
/// what the run delivers, under a lock, and returns.
public final class ProvenanceStepDeclaration: Sendable {
    /// The run the step belongs to.
    public let runID: UUID
    /// Names this declaration among its run's declarations.
    public let id = UUID()
    private let delivered = Mutex<[ToolProcessRunObservation]>([])

    init(runID: UUID) {
        self.runID = runID
    }

    /// The observer to bind around the step's one launch.
    public var observer: ToolProcessObserver {
        ToolProcessObserver { [self] observation in
            delivered.withLock { $0.append(observation) }
        }
    }

    /// The runs observed so far, in the order they were built.
    var observations: [ToolProcessRunObservation] {
        delivered.withLock { $0 }.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }
}

extension ProvenanceRecorder {
    /// Declares a step of `runID` before its tool launches. Returns the declaration whose observer the
    /// adapter binds around that one launch, or nil when the recorder holds no such run.
    public func declareStep(runID: UUID) -> ProvenanceStepDeclaration? {
        let declaration = ProvenanceStepDeclaration(runID: runID)
        guard modifyRun(runID, { $0.openDeclarations.insert(declaration.id) }) != nil else {
            logger.warning("Provenance: no active run \(runID), so no step is declared")
            return nil
        }
        return declaration
    }

    /// Writes what the declared launch did on the step `stepID`, which the caller recorded for it with
    /// `recordStep`, as the step's `observation` key, and returns the observation written.
    ///
    /// The step takes stage `stage` of the one run the declaration observed, 0 for a single run. Its
    /// argv never changes, and its exit status, times and stderr stay as the caller recorded them from
    /// the same run. The peak memory the observation carries is never written (decision P4).
    ///
    /// Nothing is written, and a log line says why, when the declaration observed no run (the launch
    /// ran outside the bound scope, or a detached task or a GCD hop dropped the binding), more than one
    /// run (the scope covered another launch, such as a probe), or a run without stage `stage`, or when
    /// the run holds no step `stepID`.
    @discardableResult
    public func recordObservation(
        of declaration: ProvenanceStepDeclaration,
        forStep stepID: UUID?,
        stage: Int = 0
    ) -> ProvenanceStepObservation? {
        let runID = declaration.runID
        _ = modifyRun(runID) { $0.openDeclarations.remove(declaration.id) }
        let observations = declaration.observations
        guard let stepID else {
            logger.warning("Provenance: declared step of run \(runID) was not recorded, so its observation is dropped")
            return nil
        }
        guard observations.count == 1, let run = observations.first else {
            logger.warning(
                "Provenance: declared step \(stepID) of run \(runID) observed \(observations.count) launches, not one, so it records no observation"
            )
            return nil
        }
        guard run.stages.indices.contains(stage) else {
            logger.warning(
                "Provenance: declared step \(stepID) of run \(runID) names stage \(stage) of a run with \(run.stages.count), so it records no observation"
            )
            return nil
        }
        let observation = ProvenanceStepObservation(run.stages[stage])
        let written = modifyRun(runID) { recorded -> Bool in
            guard let index = recorded.steps.firstIndex(where: { $0.id == stepID }) else { return false }
            recorded.steps[index].observation = observation
            return true
        }
        guard written == true else {
            logger.warning("Provenance: run \(runID) holds no step \(stepID), so its observation is dropped")
            return nil
        }
        return observation
    }

    /// Logs each step of `run` that was declared and never given its observation, which `save` calls
    /// so a lost observation is never silent.
    func logDeclarationsWithoutObservation(of run: RecordedRun) {
        for declarationID in run.openDeclarations.sorted(by: { $0.uuidString < $1.uuidString }) {
            logger.warning(
                "Provenance: run \(run.id) saved with declared step \(declarationID) whose observation was never recorded"
            )
        }
    }
}
