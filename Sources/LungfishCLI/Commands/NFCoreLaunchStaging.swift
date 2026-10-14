// NFCoreLaunchStaging.swift - Stage viralrecon's annotation under a .gff name for workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension NFCoreLaunchStaging {
    /// Copies a GFF3 annotation into the run bundle under the `.gff` name
    /// viralrecon's `gff` pattern (`^\S+\.gff(\.gz)?$`) accepts, with its bytes
    /// unchanged, through the shared `ViralReconAnnotationStaging`.
    ///
    /// A reference bundle carries its annotation as `genome/genes.gff3`, and
    /// the app launches viralrecon through `workflow run`, so the app and a
    /// direct CLI call get the same staging. The returned copy is what the
    /// engine is given. The request keeps the caller's path. A missing
    /// annotation is refused as a missing input file before anything runs.
    /// With no `gff`, the annotation database of the reference bundle that
    /// holds `fasta` is exported as GFF3 instead, as a bundle `fetch genome`
    /// wrote keeps no GFF3 file (V1-BIO ruling 3).
    ///
    /// Only nf-core/viralrecon's `gff` is renamed. Another pipeline's `gff`
    /// parameter can expect another name, so it reaches the engine as given.
    static func stageAnnotation(for request: NFCoreRunRequest, runBundleURL: URL) throws -> ViralReconStagedAnnotation? {
        // The workflow identity the launch path keys viralrecon's resource
        // limits and forced skips on (NFCoreResourceLimits, NFCoreRunRequest).
        guard request.workflow.name == "viralrecon" else { return nil }
        do {
            return try ViralReconAnnotationStaging.stage(params: request.params, inRunBundle: runBundleURL)
        } catch ViralReconAnnotationStaging.StagingError.annotationNotFound(let url) {
            throw CLIError.inputFileNotFound(path: url.path)
        } catch {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
    }
}
