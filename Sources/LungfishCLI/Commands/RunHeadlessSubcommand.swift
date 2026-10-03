// RunHeadlessSubcommand.swift - Run a workflow quietly without the GUI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct RunHeadlessSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-headless",
        abstract: "Run a workflow quietly without the GUI",
        discussion: """
            Thin alias for `lungfish-cli workflow run --quiet <workflow> ...`.
            Use `lungfish-cli workflow run --help` for the full workflow run option set.
            """
    )

    @Argument(help: "Workflow file (*.nf, Snakefile) or supported nf-core workflow to pass to workflow run")
    var workflow: String

    @Argument(
        parsing: .captureForPassthrough,
        help: "Additional workflow run options passed through after the workflow argument"
    )
    var workflowRunArguments: [String] = []

    var forwardedWorkflowRunArguments: [String] {
        let forwardedArguments = workflowRunArguments.first == "--"
            ? Array(workflowRunArguments.dropFirst())
            : workflowRunArguments
        return [workflow] + forwardedArguments + ["--quiet"]
    }

    func run() async throws {
        let command = try RunSubcommand.parse(forwardedWorkflowRunArguments)
        try await command.run()
    }
}
