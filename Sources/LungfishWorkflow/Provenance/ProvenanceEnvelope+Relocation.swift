// ProvenanceEnvelope+Relocation.swift - One relocation of a record from the folder a run built in to the place it now sits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceEnvelope {
    /// This record with every spelling of the folder `staged` replaced by `final`, wherever the record
    /// names a place. A run that builds a bundle in a staging folder and publishes it by rename calls
    /// this once the bundle is in its final place, so the record names the files where they now are
    /// (Phase 2.10 lane A45, ruling A45-M3 section 3). The builder keeps the spelling of the path it was
    /// given and a reader may resolve it, so the replaced spellings are the ones ``StagedBundlePlace``
    /// takes whether or not the staged folder still exists: the path as given, the path through its
    /// deepest existing ancestor (`/tmp`) and its real path (`/private/tmp`), the longest first.
    ///
    /// Replaced, as text and with no encoder: the run's argument vector, replay argument vector and
    /// command, the options through `ParameterValue.rewritingPaths`, the files, the output and the
    /// outputs, the standard error text, and in each step the same fields the way
    /// `ONTImportWorkflow.remapOptimizationStep` does them, with the step's inputs, standard error and
    /// the sanitized environment its launch observed. Digests, sizes, formats, roles, times and
    /// statuses are not touched. The copy goes through ``with(_:)``, so its signatures are cleared and
    /// the parameters of a nested run are rewritten with the options.
    public func relocated(from staged: URL, to final: URL) -> ProvenanceEnvelope {
        let place = StagedBundlePlace(staged: staged, final: final)
        return with { copy in
            copy.argv = copy.argv.map(place.relocating)
            copy.durableReplayArgv = copy.durableReplayArgv?.map(place.relocating)
            copy.reproducibleCommand = place.relocating(copy.reproducibleCommand)
            copy.options = ProvenanceOptions(
                explicit: place.relocating(copy.options.explicit),
                defaults: place.relocating(copy.options.defaults),
                resolvedDefaults: place.relocating(copy.options.resolvedDefaults))
            copy.files = copy.files.map(place.relocating)
            copy.output = copy.output.map(place.relocating)
            copy.outputs = copy.outputs.map(place.relocating)
            copy.steps = copy.steps.map(place.relocating)
            copy.stderr = copy.stderr.map(place.relocating)
            if var run = copy.legacyRun {
                run.parameters = place.relocating(run.parameters)
                copy.legacyRun = run
            }
        }
    }
}

/// The relocation of a step and of the observation of its launch, which hold more places than a file does.
private extension StagedBundlePlace {
    func relocating(_ step: ProvenanceStep) -> ProvenanceStep {
        step.with { copy in
            copy.argv = step.argv.map(relocating)
            copy.durableReplayArgv = step.durableReplayArgv?.map(relocating)
            copy.reproducibleCommand = relocating(step.reproducibleCommand)
            copy.resolvedOptions = relocating(step.resolvedOptions)
            copy.inputs = step.inputs.map(relocating)
            copy.outputs = step.outputs.map(relocating)
            copy.stderr = step.stderr.map(relocating)
            copy.observation = step.observation.map(relocating)
            copy.narrowedFrom = step.narrowedFrom.map {
                ProvenanceStepNarrowing(recordPath: relocating($0.recordPath), inputCount: $0.inputCount)
            }
        }
    }

    func relocating(_ observation: ProvenanceStepObservation) -> ProvenanceStepObservation {
        guard let environment = observation.environment else { return observation }
        return ProvenanceStepObservation(
            termination: observation.termination,
            stop: observation.stop,
            outputComplete: observation.outputComplete,
            environment: ProvenanceStepObservation.Environment(
                base: environment.base,
                changed: environment.changed,
                values: environment.values.mapValues(relocating),
                unset: environment.unset,
                pathPrefix: environment.pathPrefix.map(relocating)),
            stage: observation.stage)
    }
}
