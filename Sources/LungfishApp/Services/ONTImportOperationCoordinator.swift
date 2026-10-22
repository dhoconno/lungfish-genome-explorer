// ONTImportOperationCoordinator.swift - App coordinator for ONT imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import LungfishKit

/// Runs the window's ONT import as `lungfish-cli fastq import-ont --format json` on the L6 runner
/// (``CLIReadsRunner``) and reports it in the Operations panel (Phase 2.10 lane A53, panel decisions
/// C11, C4 and C5). The row records the argv the runner launches, the command speaks the stage words
/// the row showed when the import ran in the app, and the row's cancel signals the command, which
/// stops at its next chunk and rolls its staged bundles back. The command writes the bundles, their
/// manifest and every provenance record before it exits, so the app writes nothing of the result.
@MainActor
public final class ONTImportOperationCoordinator {
    /// Every report goes through this reporter, so a test can watch the row
    /// without touching `OperationCenter.shared` (finding R4). The command's own events reach
    /// `OperationCenter.shared` through ``OperationCenterCLIBridge``, which names the row by its ID.
    private let operationCenter: any OperationReporting
    private let runner: CLIReadsRunner

    /// Make one coordinator for each import. Its runner, once cancelled, stops every later run
    /// before it launches (``CLIReadsRunner``).
    public init(operationCenter: any OperationReporting = OperationCenter.shared) {
        self.operationCenter = operationCenter
        self.runner = CLIReadsRunner()
    }

    /// For a test that runs a stand-in or a built `lungfish-cli` that the bundle does not hold.
    init(
        operationCenter: any OperationReporting,
        runner: CLIReadsRunner
    ) {
        self.operationCenter = operationCenter
        self.runner = runner
    }

    /// Imports an ONT output directory with `lungfish-cli fastq import-ont` and reports the run in
    /// the Operations panel. The row locks no bundle and records the command that ran, the one a user
    /// can paste into a terminal. The bundles stay off the row until the command has finished.
    ///
    /// - Returns: The bundles the command's `complete` line named, in barcode order, and the words
    ///   the row ended on, such as `3 barcode bundles, 6 reads`.
    /// - Throws: `OperationRefusedError`, having imported nothing, when `begin` is refused.
    ///   `CancellationError` when the row's cancel stopped the command. The command's own words
    ///   (`error.localizedDescription`) when it failed.
    @discardableResult
    public func importDirectory(
        sourceURL: URL,
        projectURL: URL,
        includeUnclassified: Bool,
        concurrency: Int = 4,
        storageMode: ONTImportStorageMode = .chunked,
        optimizeStorage: Bool = false,
        qualityBinning: QualityBinningScheme = QualityBinningScheme.importDefault,
        routeContext: OperationRouteContext?
    ) async throws -> (bundleURLs: [URL], detail: String) {
        let outputURL = try Self.resolvedOutputDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: includeUnclassified
        )
        // The command prints events when asked, so the row shows the stage words the in-process row showed.
        let cliArgs = Self.cliArgs(
            sourceURL: sourceURL,
            outputURL: outputURL,
            includeUnclassified: includeUnclassified,
            concurrency: concurrency,
            storageMode: storageMode,
            optimizeStorage: optimizeStorage,
            qualityBinning: qualityBinning
        ) + ["--format", "json"]
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: cliArgs
        )
        let opID = try operationCenter.begin(
            title: "ONT Import: \(sourceURL.lastPathComponent)",
            detail: "Detecting layout...",
            operationType: .ingestion,
            cliCommand: cliCommand,
            routeContext: routeContext
        ).requireStarted()
        let runner = self.runner
        operationCenter.setCancelCallback(for: opID) { runner.cancel() }

        do {
            let run = try await runner.runEvents(arguments: ["fastq", "import-ont"] + cliArgs, operationID: opID)
            let bundleURLs = run.outputs.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let detail = run.message ?? "\(bundleURLs.count) barcode bundles"
            // A cancel that came after the command finished ends the row Cancelled. The bundles exist,
            // so they are returned and the window shows them.
            _ = operationCenter.complete(id: opID, detail: detail, bundleURLs: bundleURLs)
            return (bundleURLs, detail)
        } catch is CancellationError {
            // The command rolled its staged bundles back and exited 125. The row reads Cancelled, with no sheet.
            _ = operationCenter.acknowledgeCancellation(id: opID)
            throw CancellationError()
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

    /// The options of the command, without the `--format json` the route adds.
    nonisolated static func cliArgs(
        sourceURL: URL,
        outputURL: URL,
        includeUnclassified: Bool,
        concurrency: Int,
        storageMode: ONTImportStorageMode = .chunked,
        optimizeStorage: Bool = false,
        qualityBinning: QualityBinningScheme = QualityBinningScheme.importDefault
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
        // The binning is always named, as the command records it (lane C2-BINNING).
        args += ["--quality-binning", qualityBinning.rawValue]
        return args
    }
}
