// FASTQImportCLIInvocationBuilder.swift - Typed argv builder for `lungfish-cli import fastq`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the `lungfish-cli import fastq` argv for a pinned
/// ``ImportFASTQStepSpec``.
///
/// Mirrors the argument mapping of the GUI importer
/// (`CLIImportRunner.buildCLIArguments` in LungfishApp) but always pins the
/// pairing and the bundle name, which the recorded import argv omits. The
/// GUI importer keeps its own builder in v1; this one exists so templates
/// and the GUI produce the same flags for the same settings.
public enum FASTQImportCLIInvocationBuilder {

    /// Builds the full `import fastq` invocation for one sample.
    ///
    /// - Parameters:
    ///   - spec: The pinned import settings.
    ///   - inputs: One file (single-end or interleaved) or R1 then R2 (paired).
    ///   - projectURL: The `.lungfish` project directory to import into.
    ///   - bundleName: The output bundle name (`--name`).
    ///   - threads: Threads for native tools, or nil to leave the CLI default.
    public static func build(
        spec: ImportFASTQStepSpec,
        inputs: [URL],
        projectURL: URL,
        bundleName: String?,
        threads: Int?
    ) -> CLIInvocation {
        var arguments = ["import", "fastq"]
        arguments += inputs.map(\.path)
        arguments += ["--project", projectURL.path]
        arguments += ["--platform", spec.platform.rawValue]
        arguments += ["--pairing", spec.pairing.rawValue]
        arguments += ["--format", "json"]
        arguments += ["--quality-binning", spec.qualityBinning.rawValue]
        arguments += ["--compression", spec.compressionLevel.rawValue]
        if let bundleName, !bundleName.isEmpty {
            arguments += ["--name", bundleName]
        }
        if let recipe = spec.recipe {
            arguments += ["--recipe", recipe.id]
        }
        if !spec.optimizeStorage || spec.clumpingTool == .none {
            arguments.append("--no-optimize-storage")
        } else if spec.clumpingTool != .auto {
            arguments += ["--clumping-tool", spec.clumpingTool.rawValue]
        }
        if let threads {
            arguments += ["--threads", String(threads)]
        }
        return CLIInvocation(arguments: arguments)
    }
}
