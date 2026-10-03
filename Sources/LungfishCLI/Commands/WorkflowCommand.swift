// WorkflowCommand.swift - Workflow execution command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension NFCoreExecutor: ExpressibleByArgument {}

/// Workflow execution commands
struct WorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Execute and manage bioinformatics workflows",
        discussion: """
            Run Nextflow and Snakemake workflows. Containerised steps run
            through Docker Desktop (-profile docker); check it with
            `lungfish-cli debug container` before launching.
            """,
        subcommands: [
            RunSubcommand.self,
            ListSubcommand.self,
            WorkflowValidateSubcommand.self,
        ],
        defaultSubcommand: RunSubcommand.self
    )
}

/// Resolves the launch for a managed engine; injectable so tests can point
/// the runner at an empty tool root without touching `~/.lungfish`.
typealias WorkflowEngineLaunchResolver = @Sendable (_ executableName: String, _ homeDirectory: URL) throws -> WorkflowEngineLaunch
