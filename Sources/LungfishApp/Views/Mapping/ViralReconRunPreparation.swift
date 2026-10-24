// ViralReconRunPreparation.swift - Builds the Viral Recon run request away from the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// What the Viral Recon sheet's Run button copies while its state is still on the main actor.
///
/// The builder reads only this snapshot, so it can run in a detached task. The platform, output root and primer
/// scheme stay optional here so the builder refuses a missing one in the same place, and the same order, as the
/// sheet did when it built the request itself.
struct ViralReconRunInputs: Sendable {
    let platform: ViralReconPlatform?
    let outputRoot: URL?
    let primerBundleURL: URL?
    let resolvedInputs: [ViralReconResolvedInput]
    /// The parsed advanced field, empty when it failed to parse.
    let advancedParameters: [String: String]
    /// Why the advanced field failed to parse, which refuses the run after the inputs are staged.
    let advancedError: String?
    let minimumMappedReads: Int
    let advancedGFFURL: URL?
    let projectURL: URL?
}

/// Stages the inputs of a Viral Recon run and builds its request.
///
/// The staging folder, the samplesheet, the primer BED and FASTA, and the bundled pin all read or write files, and the
/// primer FASTA is cut from a gzip reference through a child gzip. None of that may run on the main actor (the debug
/// app traps a blocking ToolProcess call there), so the sheet hands this builder a ``ViralReconRunInputs`` snapshot in a
/// detached task and takes the request back on the main actor.
enum ViralReconRunPreparation {
    enum WizardError: Error, LocalizedError {
        case missingPlatform
        case missingOutputRoot
        case missingPrimer
        case invalidAdvancedParameters(String)

        var errorDescription: String? {
            switch self {
            case .missingPlatform:
                return "select a platform."
            case .missingOutputRoot:
                return "choose a project or output location."
            case .missingPrimer:
                return "select a SARS-CoV-2 primer scheme."
            case .invalidAdvancedParameters(let message):
                return message
            }
        }
    }

    /// Docker is the only executor that reaches a working run, so it is fixed
    /// here rather than offered. The launch path refuses the others outright.
    private static let fixedExecutor: NFCoreExecutor = .docker
    private static let defaultVariantCaller: ViralReconVariantCaller = .ivar
    private static let defaultConsensusCaller: ViralReconConsensusCaller = .bcftools

    nonisolated static func buildRequest(from inputs: ViralReconRunInputs) throws -> ViralReconRunRequest {
        guard let platform = inputs.platform else {
            throw WizardError.missingPlatform
        }
        guard let outputRoot = inputs.outputRoot else {
            throw WizardError.missingOutputRoot
        }
        guard let primerBundleURL = inputs.primerBundleURL else {
            throw WizardError.missingPrimer
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let stagingDirectory = outputRoot.appendingPathComponent(".viralrecon-inputs-\(token)", isDirectory: true)
        let outputDirectory = outputRoot.appendingPathComponent("viralrecon-results-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let samples = try ViralReconInputResolver.makeSamples(from: inputs.resolvedInputs)
        let samplesheetURL: URL
        var fastqPassDirectoryURL: URL?
        switch platform {
        case .illumina:
            samplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: stagingDirectory)
        case .nanopore:
            let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: stagingDirectory)
            samplesheetURL = staged.samplesheetURL
            fastqPassDirectoryURL = staged.fastqPassDirectory
        }

        let primer = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: primerBundleURL,
            projectURL: inputs.projectURL,
            destinationDirectory: stagingDirectory
        )

        if let message = inputs.advancedError {
            throw WizardError.invalidAdvancedParameters(message)
        }
        let advancedParams = defaultResourceParams().merging(inputs.advancedParameters) { _, override in override }

        return try ViralReconRunRequest(
            samples: samples,
            platform: platform,
            protocol: .amplicon,
            samplesheetURL: samplesheetURL,
            outputDirectory: outputDirectory,
            executor: fixedExecutor,
            // The commit the lock pins, the one source of the revision (Phase 2.10 N2). A lock without it refuses here.
            version: try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin().revision,
            reference: .genome(ViralReconReferenceCatalog.canonicalAccession),
            primer: primer,
            minimumMappedReads: inputs.minimumMappedReads,
            variantCaller: defaultVariantCaller,
            consensusCaller: defaultConsensusCaller,
            skipOptions: Array(ViralReconSkipOption.defaultSelection).sorted { $0.rawValue < $1.rawValue },
            advancedParams: advancedParams,
            gffURL: inputs.advancedGFFURL,
            fastqPassDirectoryURL: fastqPassDirectoryURL
        )
    }

    private static func defaultResourceParams() -> [String: String] {
        [
            "max_cpus": String(max(1, min(ProcessInfo.processInfo.processorCount, 8))),
            "max_memory": "8.GB",
        ]
    }
}
