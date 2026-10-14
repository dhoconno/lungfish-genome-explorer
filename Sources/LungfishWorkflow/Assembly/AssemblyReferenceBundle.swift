// AssemblyReferenceBundle.swift - The reference bundle a managed assembly publishes beside its folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Publishes the `.lungfishref` bundle of a finished managed assembly, the bundle Reassemble opens.
///
/// The app's Reassemble route and `lungfish-cli assemble --reference-bundle` both call
/// ``publish(result:request:requestedInputURLs:originalInputURLs:materializationStartedAt:materializationEndedAt:readSets:outputDirectory:bundleName:progress:)``,
/// so the two routes build the same bundle and report the same words at the same fractions
/// (Phase 2.10 lane A46, ruling on the reference bundle).
public enum AssemblyReferenceBundle {
    /// Where the bundle starts, as a fraction of the whole run.
    public static let startFraction = 0.92
    /// The words of the step that starts the bundle.
    public static let startMessage = "Creating reference bundle..."

    /// The bundle ``publish(result:request:requestedInputURLs:originalInputURLs:materializationStartedAt:materializationEndedAt:readSets:outputDirectory:bundleName:progress:)``
    /// writes for `bundleName` in `outputDirectory`.
    public static func bundleURL(outputDirectory: URL, bundleName: String) -> URL {
        AssemblyBundleBuilder.publishedBundle(outputDirectory: outputDirectory, bundleName: bundleName).url
    }

    /// Reports ``startMessage`` at ``startFraction``, computes the run's input records and the
    /// steps that wrote its execution inputs, builds the bundle and reports each of its steps at
    /// `0.92 + f * 0.08`. Returns the published bundle.
    ///
    /// - Parameters:
    ///   - result: The pipeline's result.
    ///   - request: The request the pipeline ran, its inputs the execution files.
    ///   - requestedInputURLs: The inputs the user gave.
    ///   - originalInputURLs: The input each execution file came from, one for each.
    ///   - readSets: The read sets a sample of pairs and single reads resolved to, which record
    ///     the splits that wrote its files.
    ///   - outputDirectory: The folder the bundle goes in, beside the pipeline's folder.
    ///   - bundleName: The bundle's name, the project name.
    ///   - progress: Each step's fraction of the whole run and its words, in order.
    public static func publish(
        result: AssemblyResult,
        request: AssemblyRunRequest,
        requestedInputURLs: [URL],
        originalInputURLs: [URL],
        materializationStartedAt: Date?,
        materializationEndedAt: Date?,
        readSets: AssemblyResolvedInputs?,
        outputDirectory: URL,
        bundleName: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        progress(startFraction, startMessage)
        let inputs = try await ManagedAssemblyProvenanceInputs.managedAssemblyProvenanceInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: request.inputURLs,
            startedAt: materializationStartedAt,
            endedAt: materializationEndedAt,
            readSets: readSets
        )
        let provenance = ProvenanceBuilder.build(
            request: request,
            result: result,
            inputRecords: inputs.records,
            requestedInputURLs: requestedInputURLs,
            steps: inputs.steps
        )
        return try await AssemblyBundleBuilder().build(
            result: result,
            request: request,
            provenance: provenance,
            outputDirectory: outputDirectory,
            bundleName: bundleName
        ) { fraction, message in
            progress(startFraction + fraction * 0.08, message)
        }
    }

    /// The step a run record names a published bundle with, the `Assembly Bundle Wrapping` that the
    /// bundle's own record names. Its outputs are the bundle and then each of its files with its
    /// SHA-256, and its inputs are `inputs`, the assembler's outputs that the bundle wraps. A run
    /// record's `output` is its last step's first output, so the bundle comes first and the record
    /// names it (BIO's ruling D1 on Phase 2.10 lane A46 M3).
    public static func wrappingStep(
        bundleURL: URL,
        inputs: [ProvenanceFileDescriptor],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceStep {
        let descriptors = try AssemblyBundleBuilder().assemblyBundleOutputDescriptors(bundleURL: bundleURL)
        let bundlePath = bundleURL.standardizedFileURL.path
        return ProvenanceStep(
            toolName: "Assembly Bundle Wrapping",
            toolVersion: WorkflowRun.currentAppVersion,
            inputs: inputs,
            outputs: descriptors.filter { $0.path == bundlePath } + descriptors.filter { $0.path != bundlePath },
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
