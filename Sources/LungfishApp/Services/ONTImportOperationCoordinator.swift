// ONTImportOperationCoordinator.swift - App coordinator for ONT imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

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
        storageMode: ONTImportStorageMode = .chunked,
        optimizeStorage: Bool = false,
        qualityBinning: QualityBinningScheme = .none,
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
            concurrency: concurrency,
            storageMode: storageMode,
            optimizeStorage: optimizeStorage,
            qualityBinning: qualityBinning
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
                includeUnclassified: includeUnclassified,
                storageMode: storageMode
            )
            let result = try await workflow.importDirectory(
                config: config,
                context: Self.commandContext(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    includeUnclassified: includeUnclassified,
                    concurrency: concurrency,
                    storageMode: storageMode,
                    optimizeStorage: optimizeStorage,
                    qualityBinning: qualityBinning,
                    cliArgs: cliArgs,
                    cliCommand: cliCommand
                ),
                optimization: ONTImportWorkflow.OptimizationConfig(
                    optimizeStorage: optimizeStorage,
                    qualityBinning: qualityBinning,
                    threads: concurrency
                )
            ) { [operationCenter, opID] fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = operationCenter.update(id: opID, progress: fraction, detail: message)
                    }
                }
            }

            let detail = "\(result.importResult.bundleURLs.count) barcode bundles, \(result.importResult.totalReadCount) reads"
            _ = operationCenter.complete(
                id: opID,
                detail: detail,
                bundleURLs: result.importResult.bundleURLs
            )
            return result
        } catch {
            // Show the user-facing localized message, not the raw
            // enum/struct description; keep the raw text for diagnostics.
            _ = operationCenter.fail(
                id: opID,
                detail: error.localizedDescription,
                errorMessage: error.localizedDescription,
                errorDetail: "\(error)"
            )
            throw error
        }
    }

    /// Project folder that receives imported read bundles. Every other
    /// import route (Import Center, sidebar drops, the CLI import runner)
    /// writes under this folder, so ONT run folders do too.
    nonisolated static let importsFolderName = "Imports"

    /// Resolves `<project>/Imports/<run name>/`, the folder the per-barcode
    /// bundles are written into.
    ///
    /// The run name comes from the folder around `fastq_pass` (or the
    /// selected barcode folder). A run folder that already holds ONT output
    /// (a demux manifest, provenance, or a bundle for one of the barcodes
    /// about to be written) is never reused; a numbered sibling is chosen
    /// instead so an earlier import is not overwritten. Projects whose ONT
    /// bundles were written at the project root by earlier releases keep
    /// opening as before; only new imports move under `Imports/`.
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

        let importsURL = projectURL.appendingPathComponent(importsFolderName, isDirectory: true)
        let baseName = sanitizedOutputFolderName(
            suggestedOutputFolderName(sourceURL: sourceURL)
        )
        var counter = 1
        var candidate = importsURL.appendingPathComponent(baseName, isDirectory: true)
        while fileManager.fileExists(atPath: candidate.path),
              hasONTOutputConflict(
                in: candidate,
                barcodeDirectories: barcodeDirectories,
                fileManager: fileManager
              ) {
            counter += 1
            candidate = importsURL.appendingPathComponent("\(baseName) \(counter)", isDirectory: true)
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

    /// Names the run after the folder around `fastq_pass`. Selecting
    /// `fastq_pass` itself, or one `barcodeNN`/`unclassified` folder inside
    /// it, climbs to that same run folder.
    nonisolated static func suggestedOutputFolderName(sourceURL: URL) -> String {
        var url = sourceURL
        var climbed = false
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("barcode") || name == "unclassified" {
            url = url.deletingLastPathComponent()
            climbed = true
        }
        if url.lastPathComponent.lowercased() == "fastq_pass" {
            url = url.deletingLastPathComponent()
            climbed = true
        }
        return climbed ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
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
        concurrency: Int,
        storageMode: ONTImportStorageMode = .chunked,
        optimizeStorage: Bool = false,
        qualityBinning: QualityBinningScheme = .none
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
        if storageMode != .chunked {
            args += ["--storage-mode", storageMode.rawValue]
        }
        if optimizeStorage {
            args.append("--optimize-storage")
        }
        if qualityBinning != .none {
            args += ["--quality-binning", qualityBinning.rawValue]
        }
        return args
    }

    nonisolated static func commandContext(
        sourceURL: URL,
        outputURL: URL,
        includeUnclassified: Bool,
        concurrency: Int,
        storageMode: ONTImportStorageMode = .chunked,
        optimizeStorage: Bool = false,
        qualityBinning: QualityBinningScheme = .none,
        cliArgs: [String],
        cliCommand: String
    ) -> ONTImportWorkflow.CommandContext {
        let argv = [CLICommandIdentity.executableName, "fastq", "import-ont"] + cliArgs
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
                "storageMode": .string(storageMode.rawValue),
                "optimizeStorage": .boolean(optimizeStorage),
                "qualityBinning": .string(qualityBinning.rawValue),
            ],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "storageMode": .string(ONTImportStorageMode.chunked.rawValue),
                "optimizeStorage": .boolean(false),
                "qualityBinning": .string(QualityBinningScheme.none.rawValue),
                "useVirtualConcatenation": .boolean(true),
            ],
            resolvedOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(includeUnclassified),
                "concurrency": .integer(concurrency),
                "storageMode": .string(storageMode.rawValue),
                "optimizeStorage": .boolean(optimizeStorage),
                "qualityBinning": .string(qualityBinning.rawValue),
                "useVirtualConcatenation": .boolean(storageMode.usesVirtualConcatenation),
                "caller": .string("gui"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity()
        )
    }
}
