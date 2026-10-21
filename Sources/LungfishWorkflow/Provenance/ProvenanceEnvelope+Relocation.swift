// ProvenanceEnvelope+Relocation.swift - One relocation of a record from the folder a run built in to the place it now sits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceEnvelope {
    /// This record with every spelling of the folder `staged` replaced by `final`, wherever the record
    /// names a place. A run that builds a bundle in a staging folder and publishes it by rename calls
    /// this once the bundle is in its final place, so the record names the files where they now are
    /// (Phase 2.10 lane A45, ruling A45-M3 section 3). The builder keeps the spelling of the path it was
    /// given and a reader may resolve it, so the replaced spellings are the path as given, the path with
    /// its symbolic links resolved and the path under `/private`, the longest first.
    ///
    /// Replaced, as text and with no encoder: the run's argument vector, replay argument vector and
    /// command, the options through `ParameterValue.rewritingPaths`, the files, the output and the
    /// outputs, the standard error text, and in each step the same fields the way
    /// `ONTImportWorkflow.remapOptimizationStep` does them, with the step's inputs, standard error and
    /// the sanitized environment its launch observed. Digests, sizes, formats, roles, times and
    /// statuses are not touched. The copy goes through ``with(_:)``, so its signatures are cleared and
    /// the parameters of a nested run are rewritten with the options.
    public func relocated(from staged: URL, to final: URL) -> ProvenanceEnvelope {
        let place = ProvenancePlaceRelocation(from: staged, to: final)
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

/// The text replacement `ProvenanceEnvelope.relocated(from:to:)` applies to each field it covers.
private struct ProvenancePlaceRelocation {
    /// Every spelling of the staged folder, the longest first, so `/private/var/x` goes whole before
    /// `/var/x` is looked for. Equal lengths keep a fixed order.
    let spellings: [String]
    let target: String

    init(from staged: URL, to final: URL) {
        let candidates: Set<String> = [
            staged.path,
            staged.resolvingSymlinksInPath().path,
            "/private" + staged.path,
        ]
        spellings = candidates
            .filter { !$0.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        target = final.path
    }

    func relocating(_ text: String) -> String {
        spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: target) }
    }

    func relocating(_ values: [String: ParameterValue]) -> [String: ParameterValue] {
        values.mapValues { $0.rewritingPaths(relocating) }
    }

    func relocating(_ descriptor: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: relocating(descriptor.path),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map(relocating),
            sourceProvenancePath: descriptor.sourceProvenancePath.map(relocating))
    }

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
