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
        let outputURL = try Self.resolvedOutputDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: includeUnclassified
        )
        let cliArgs = Self.cliArgs(
            sourceURL: sourceURL,
            outputURL: outputURL,
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
                outputDirectory: outputURL,
                maxConcurrentBarcodes: concurrency,
                includeUnclassified: includeUnclassified
            )
            let result = try await workflow.importDirectory(
                config: config,
                context: Self.commandContext(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
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

    nonisolated static func resolvedOutputDirectory(
        sourceURL: URL,
        projectURL: URL,
        includeUnclassified: Bool,
        fileManager: FileManager = .default,
        importer: ONTDirectoryImporter = ONTDirectoryImporter()
    ) throws -> URL {
        let layout = try importer.detectLayout(at: sourceURL)
        let barcodeDirectories = layout.barcodeDirectories.filter {
            includeUnclassified || !$0.isUnclassified
        }

        guard hasONTOutputConflict(
            in: projectURL,
            barcodeDirectories: barcodeDirectories,
            fileManager: fileManager
        ) else {
            return projectURL
        }

        let baseName = sanitizedOutputFolderName(
            suggestedOutputFolderName(sourceURL: sourceURL)
        )
        var counter = 1
        var candidate = projectURL.appendingPathComponent(baseName, isDirectory: true)
        while fileManager.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = projectURL.appendingPathComponent("\(baseName) \(counter)", isDirectory: true)
        }
        return candidate
    }

    nonisolated private static func hasONTOutputConflict(
        in outputURL: URL,
        barcodeDirectories: [ONTBarcodeDirectory],
        fileManager: FileManager
    ) -> Bool {
        let rootOutputURLs = [
            outputURL.appendingPathComponent(DemultiplexManifest.filename),
            outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename),
        ]
        if rootOutputURLs.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
            return true
        }

        for barcodeDirectory in barcodeDirectories {
            let bundleURL = outputURL.appendingPathComponent(
                "\(barcodeDirectory.barcodeName).\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: bundleURL.path) {
                return true
            }
            if ProjectDeletionPlanner.companionSidecarCandidates(for: bundleURL)
                .contains(where: { fileManager.fileExists(atPath: $0.path) }) {
                return true
            }
        }

        return false
    }

    nonisolated private static func suggestedOutputFolderName(sourceURL: URL) -> String {
        let name = sourceURL.lastPathComponent
        let lowercased = name.lowercased()
        if lowercased == "fastq_pass"
            || lowercased.hasPrefix("barcode")
            || lowercased == "unclassified" {
            return sourceURL.deletingLastPathComponent().lastPathComponent
        }
        return sourceURL.deletingPathExtension().lastPathComponent
    }

    nonisolated private static func sanitizedOutputFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "ONT Import" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let sanitized = String(fallback.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "ONT Import" : sanitized
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
