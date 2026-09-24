// MappingCLIInvocationBuilder.swift - The `lungfish-cli map` arguments that reproduce a mapping request
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Builds the `lungfish-cli map` argument list for a ``MappingRunRequest`` so
/// the Operations panel's `Copy CLI Command` reproduces a GUI run.
///
/// The inputs are the ORIGINAL bundle URLs the user chose (a copied command
/// must not point at a scratch file). The read layout is pinned with
/// `--read-layout` only when the request already resolved it for a single
/// file; otherwise the CLI's `auto` runs the same `FASTQInputLayoutResolver`
/// the GUI pipeline uses, so both surfaces reach the same decision.
public enum MappingCLIInvocationBuilder {
    /// Arguments after the `map` subcommand.
    public static func arguments(
        for request: MappingRunRequest,
        inputURLs: [URL]? = nil
    ) -> [String] {
        let inputs = inputURLs ?? request.originalInputFASTQURLs ?? request.inputFASTQURLs
        var arguments = inputs.map(\.path)
        arguments += ["--reference", request.referenceFASTAURL.path]
        arguments += ["--mapper", request.tool.rawValue]
        if let preset = presetArgument(for: request) {
            arguments += ["--preset", preset]
        }
        arguments += ["--output-dir", request.outputDirectory.path]
        arguments += ["--sample-name", request.sampleName]
        if let readGroup = request.readGroup {
            arguments += [
                "--rg-id", readGroup.id,
                "--rg-sm", readGroup.sampleName,
                "--rg-lb", readGroup.library,
                "--rg-pl", readGroup.platform,
                "--rg-pu", readGroup.platformUnit,
            ]
        }
        if request.pairedEnd, inputs.count == 2 {
            arguments.append("--paired")
        } else if inputs.count == 1, let readLayoutArgument = readLayoutArgument(for: request.inputLayout) {
            arguments += ["--read-layout", readLayoutArgument]
        }
        arguments += ["--threads", String(request.threads)]
        if request.includeSecondary {
            arguments.append("--secondary")
        }
        if !request.includeSupplementary {
            arguments.append("--no-supplementary")
        }
        if request.minimumMappingQuality > 0 {
            arguments += ["--min-mapq", String(request.minimumMappingQuality)]
        }
        if !request.advancedArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.advancedArguments)]
        }
        return arguments
    }

    /// The `--read-layout` value that pins a resolved single-file layout, or
    /// `nil` to leave the CLI in `auto`.
    public static func readLayoutArgument(for layout: FASTQInputLayout?) -> String? {
        switch layout {
        case .singleEnd: return "single-end"
        case .strictlyInterleaved: return "interleaved"
        case .mixedMergedAndPairs: return "mixed"
        case .pairedFiles, .none: return nil
        }
    }

    private static func presetArgument(for request: MappingRunRequest) -> String? {
        guard let mode = MappingMode(rawValue: request.modeID) else { return nil }
        switch request.tool {
        case .minimap2:
            return mode.commandPresetValue
        case .bbmap:
            return mode.rawValue
        case .bwaMem2, .bowtie2:
            return nil
        }
    }
}
