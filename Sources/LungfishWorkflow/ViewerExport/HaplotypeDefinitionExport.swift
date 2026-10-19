// HaplotypeDefinitionExport.swift - The definition export the haplotype manager and `haplotypes export` share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The export of one haplotype definition set to a JSON file (Phase 2.12 lane 12.35, ARCH ruling 1.1 row B7).
public enum HaplotypeDefinitionExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["haplotypes", "export"]

    /// The leaf's argv without the executable, `haplotypes export <id> --output <file> [--project <root>]
    /// [--assay <id>] [--scope <scope>]`, in one fixed order.
    ///
    /// The haplotype manager's begin helper passes it to the runner and to the row's command, and the leaf records
    /// ``canonicalArgv(definitionID:outputPath:projectPath:assayID:scope:)``, so the row and the record name one
    /// command with every option the export used (ARCH 2, `docs/contracts/CLI-EQUIVALENCE.md`).
    public static func arguments(
        definitionID: String,
        outputPath: String,
        projectPath: String?,
        assayID: String?,
        scope: String?
    ) -> [String] {
        var arguments = commandPath + [definitionID, "--output", outputPath]
        if let projectPath {
            arguments += ["--project", projectPath]
        }
        if let assayID {
            arguments += ["--assay", assayID]
        }
        if let scope {
            arguments += ["--scope", scope]
        }
        return arguments
    }

    /// The argv the leaf records, which starts with ``CLICommandIdentity/executableName``.
    public static func canonicalArgv(
        definitionID: String,
        outputPath: String,
        projectPath: String?,
        assayID: String?,
        scope: String?
    ) -> [String] {
        [CLICommandIdentity.executableName] + arguments(
            definitionID: definitionID,
            outputPath: outputPath,
            projectPath: projectPath,
            assayID: assayID,
            scope: scope
        )
    }
}
