// ClassifierLaunchDeclaration.swift - The declared launch of a classifier step, whose observation reaches its step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The one launch of a kraken2, Bracken or EsViritu step that a classifier pipeline declares to its recorder before
/// the tool runs (`docs/contracts/RECORDING-PROVENANCE.md`, "The ToolProcess observer hook").
///
/// The pipeline passes ``observer`` to `CondaManager.runTool`, which binds it around that launch alone, so a probe
/// through the same adapter, such as `bracken --help` or a version probe, never reaches the step. Whichever step the
/// pipeline then records for the launch, on success, failure or cancel, takes its observation through
/// ``recordObservation(onStep:)``.
struct ClassifierLaunchDeclaration: Sendable {
    private let recorder: ProvenanceRecorder
    private let declaration: ProvenanceStepDeclaration?

    /// Declares a step of `runID` just before its tool launches.
    init(recorder: ProvenanceRecorder, runID: UUID) async {
        self.recorder = recorder
        declaration = await recorder.declareStep(runID: runID)
    }

    /// The observer to bind around the step's one launch, or nil when the recorder holds no such run.
    var observer: ToolProcessObserver? {
        declaration?.observer
    }

    /// Writes what the launch did as the `observation` of `stepID`, the step the pipeline recorded for it. The
    /// recorder logs, and writes nothing, when the launch never ran or ran more than once in the bound scope.
    func recordObservation(onStep stepID: UUID?) async {
        guard let declaration else { return }
        await recorder.recordObservation(of: declaration, forStep: stepID)
    }
}
