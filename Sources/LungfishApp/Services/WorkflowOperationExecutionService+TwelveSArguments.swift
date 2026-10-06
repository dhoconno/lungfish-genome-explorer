// WorkflowOperationExecutionService+TwelveSArguments.swift - The command a 12S matching run records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved from WorkflowOperationExecutionService.swift in Phase 2.1 lane L4,
// so the service file stays within its file-size baseline.

import Foundation
import LungfishIO
import LungfishWorkflow

extension WorkflowOperationExecutionService {

    func twelveSAmpliconMatchingArguments(for configuration: TwelveSAmpliconMatchingConfiguration) -> [String] {
        var arguments = ["fastq", "12s-match"] + configuration.inputFASTQs.map(\.path)
        let referenceURL = configuration.referenceBundleURL ?? configuration.referenceFASTA
        arguments += [
            "--reference", referenceURL.path,
        ]
        if let referenceMetadata = configuration.referenceMetadata,
           !Self.isBundledTwelveSReferenceMetadata(referenceMetadata, bundleURL: configuration.referenceBundleURL) {
            arguments += ["--reference-metadata", referenceMetadata.path]
        }
        if let sampleMetadata = configuration.sampleMetadata {
            arguments += ["--sample-metadata", sampleMetadata.path]
        }
        arguments += [
            "--output-dir", configuration.outputDirectory.path,
            "--output-name", configuration.outputName,
        ]
        if configuration.minimumSoftClipBases != 1 {
            arguments += ["--min-soft-clip", String(configuration.minimumSoftClipBases)]
        }
        if configuration.maximumIndelBases != 3 {
            arguments += ["--max-indels", String(configuration.maximumIndelBases)]
        }
        // The same choices, in the same order and with the same defaults left
        // out, as `FastqTwelveSMatchSubcommand.replayArgv`, so the row's
        // command and the provenance argv are the same command. The mode is
        // always named, and so is the thread count, because the CLI's default
        // is every core.
        arguments += ["--matching-mode", configuration.matchingMode.rawValue]
        arguments += ["--threads", String(configuration.threads)]
        if !configuration.runChimeraReview {
            arguments.append("--no-chimera-review")
        }
        if configuration.ambiguityResolution != .anyNonzeroLead {
            arguments += ["--ambiguity-resolution", configuration.ambiguityResolution.cliValue]
        }
        if configuration.forceOverwrite {
            arguments.append("--force")
        }
        return arguments
    }

    static func isBundledTwelveSReferenceMetadata(_ metadataURL: URL, bundleURL: URL?) -> Bool {
        guard let bundleURL,
              let bundledURL = TwelveSReferenceBundle.targetMetadataURL(in: bundleURL) else {
            return false
        }
        return metadataURL.standardizedFileURL == bundledURL.standardizedFileURL
    }
}
