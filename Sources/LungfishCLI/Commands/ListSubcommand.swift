// ListSubcommand.swift - List available workflows
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - List Subcommand

/// List available workflows
struct ListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available workflows"
    )

    @Flag(
        name: .customLong("nf-core"),
        help: "List the supported nf-core Viral Recon pipeline"
    )
    var nfCore: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if nfCore {
            print(formatter.header("Supported nf-core Pipeline"))
            if let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon") {
                print("  \(formatter.colored(workflow.fullName, .cyan)): \(workflow.description)")
            }
        } else {
            print(formatter.info("Use --nf-core to list the supported nf-core Viral Recon pipeline"))
            print(formatter.info("Or provide a local workflow file path to 'workflow run'"))
        }
    }
}
