// ONTImportOperationCoordinator.swift - App coordinator for ONT imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
public final class ONTImportOperationCoordinator {
    private let operationCenter: OperationCenter
    private let workflow: ONTImportWorkflow

    public init(
        operationCenter: OperationCenter = .shared,
        workflow: ONTImportWorkflow = ONTImportWorkflow()
    ) {
        self.operationCenter = operationCenter
        self.workflow = workflow
    }

    @discardableResult
    public func importDirectory(
        sourceURL: URL,
        projectURL: URL,
        includeUnclassified: Bool,
        concurrency: Int = 4,
        routeContext: OperationRouteContext?
    ) async throws -> ONTImportWorkflow.Result {
        let cliArgs = Self.cliArgs(
            sourceURL: sourceURL,
            outputURL: projectURL,
            includeUnclassified: includeUnclassified,
            concurrency: concurrency
        )
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: cliArgs
        )
        let opID = operationCenter.start(
            title: "ONT Import: \(sourceURL.lastPathComponent)",
            detail: "Detecting layout...",
            operationType: .ingestion,
            cliCommand: cliCommand,
            routeContext: routeContext
        )

        do {
            let config = ONTImportConfig(
                sourceDirectory: sourceURL,
                outputDirectory: projectURL,
                maxConcurrentBarcodes: concurrency,
                includeUnclassified: includeUnclassified
            )
            let result = try await workflow.importDirectory(
                config: config,
                context: Self.commandContext(
                    sourceURL: sourceURL,
                    outputURL: projectURL,
                    includeUnclassified: includeUnclassified,
                    concurrency: concurrency,
                    cliArgs: cliArgs,
                    cliCommand: cliCommand
                )
            ) { [operationCenter, opID] fraction, message in
                Task { @MainActor in
                    operationCenter.update(id: opID, progress: fraction, detail: message)
                }
            }

            let detail = "\(result.importResult.bundleURLs.count) barcode bundles, \(result.importResult.totalReadCount) reads"
            operationCenter.complete(
                id: opID,
                detail: detail,
                bundleURLs: result.importResult.bundleURLs
            )
            return result
        } catch {
            operationCenter.fail(id: opID, detail: "\(error)")
            throw error
        }
    }

    nonisolated static func cliArgs(
        sourceURL: URL,
        outputURL: URL,
        includeUnclassified: Bool,
        concurrency: Int
    ) -> [String] {
        var args = [
            sourceURL.path,
            "--output", outputURL.path,
        ]
        if includeUnclassified {
            args.append("--include-unclassified")
        }
        if concurrency != 4 {
            args += ["--concurrency", String(concurrency)]
        }
        return args
    }

    nonisolated static func commandContext(
        sourceURL: URL,
        outputURL: URL,
        includeUnclassified: Bool,
        concurrency: Int,
        cliArgs: [String],
        cliCommand: String
    ) -> ONTImportWorkflow.CommandContext {
        let argv = ["lungfish", "fastq", "import-ont"] + cliArgs
        return ONTImportWorkflow.CommandContext(
            caller: .gui,
            workflowName: "lungfish fastq import-ont",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish fastq import-ont",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: cliCommand,
            explicitOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(includeUnclassified),
                "concurrency": .integer(concurrency),
            ],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "useVirtualConcatenation": .boolean(true),
            ],
            resolvedOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(includeUnclassified),
                "concurrency": .integer(concurrency),
                "useVirtualConcatenation": .boolean(true),
                "caller": .string("gui"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity()
        )
    }
}
