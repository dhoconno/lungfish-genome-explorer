// AssembleCommand+ReferenceBundle.swift - The reference bundle `assemble --reference-bundle` publishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// A reference bundle that `--reference-bundle` published, with the times its step took.
struct PublishedReferenceBundle: Sendable {
    let url: URL
    let startedAt: Date
    let endedAt: Date

    /// The run record's `Assembly Bundle Wrapping` step, which names the bundle and each of its files
    /// with its SHA-256. Its inputs are `inputs`, the assembler's outputs the bundle wraps.
    func wrappingStep(inputs: [ProvenanceFileDescriptor]) throws -> ProvenanceStep {
        try AssemblyReferenceBundle.wrappingStep(bundleURL: url, inputs: inputs, startedAt: startedAt, completedAt: endedAt)
    }
}

extension AssembleCommand {
    /// The bundle `--reference-bundle` publishes beside `outputDirectory`, the pipeline's folder,
    /// named after the project, or nil without the flag (Phase 2.10 lane A46, the ruling on the
    /// reference bundle). A bundle already there refuses the run with exit 3 before the assembler
    /// starts, as the app's Reassemble route fails once the assembler has run.
    func refusingAnExistingReferenceBundle(
        outputDirectory: URL,
        projectName: String,
        reporter: AssembleRunReporter
    ) throws -> URL? {
        guard referenceBundle else { return nil }
        let bundleURL = AssemblyReferenceBundle.bundleURL(
            outputDirectory: outputDirectory.deletingLastPathComponent(),
            bundleName: projectName
        )
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw reporter.refusal(
                AssemblyBundleBuildError.outputBundleAlreadyExists(bundleURL).localizedDescription,
                exit: .inputError
            )
        }
        return bundleURL
    }

    /// Publishes the bundle at `bundleURL` once the assembler has finished, through the function
    /// the app's Reassemble route calls, so each step prints the words and the fraction from 0.92
    /// the route shows. Returns nil without the flag. Nothing checks for a cancel after the bundle
    /// is out, so a run that published it ends 0 even after a late cancel.
    func publishReferenceBundle(
        at bundleURL: URL?,
        result: AssemblyResult,
        request: AssemblyRunRequest,
        requestedInputURLs: [URL],
        readSets: AssemblyResolvedInputs,
        projectName: String,
        reporter: AssembleRunReporter,
        showHumanOutput: Bool
    ) async throws -> PublishedReferenceBundle? {
        guard let bundleURL else { return nil }
        let startedAt = Date()
        do {
            let published = try await AssemblyReferenceBundle.publish(
                result: result,
                request: request,
                requestedInputURLs: requestedInputURLs,
                originalInputURLs: readSets.inputs.originalInputURLs,
                materializationStartedAt: readSets.inputs.materializationStartedAt,
                materializationEndedAt: readSets.inputs.materializationEndedAt,
                readSets: readSets,
                outputDirectory: bundleURL.deletingLastPathComponent(),
                bundleName: projectName
            ) { fraction, message in
                reporter.progress(fraction, message)
                if showHumanOutput { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            }
            return PublishedReferenceBundle(url: published, startedAt: startedAt, endedAt: Date())
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw reporter.refusal(error.localizedDescription, exit: .workflowError)
        }
    }
}
