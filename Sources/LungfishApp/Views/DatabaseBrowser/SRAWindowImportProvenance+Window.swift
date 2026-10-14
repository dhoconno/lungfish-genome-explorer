// SRAWindowImportProvenance+Window.swift - The window's call of the SRA import provenance writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// Writes the provenance of one SRA run the window downloaded and imported, naming the CLI the
/// window located and the line `CLIImportRunner` shows for the import (Phase 2.10 lane A45 M3).
///
/// The writer itself reads nothing from the app, so `fetch sra download --bundle` calls it too. The
/// window and its tests call this one, which passes `CLIImportRunner`'s answers.
///
/// `cliBinaryPath` names the CLI in the import step. Tests pass a fixed path, because the default
/// can run `swift build --show-bin-path`, which waits on the build lock `swift test` holds.
func writeGUISRAFASTQImportProvenance(
    accession: String,
    readRecord: ENAReadRecord?,
    downloadSource: String,
    preferredSource: SRADownloadSourcePreference = .ena,
    layoutWarning: String? = nil,
    fallbackMessage: String? = nil,
    enaDownloadSteps: [StepExecution],
    toolkitDownloadTraces: [SRAService.FASTQDownloadStepTrace],
    cliArguments: [String],
    cliStartedAt: Date,
    cliCompletedAt: Date,
    stagedFASTQFiles: [URL],
    stagedReadCounts: [URL: Int]? = nil,
    finalFASTQURL: URL,
    bundleURL: URL,
    platform: String,
    recipeName: String?,
    qualityBinning: String,
    optimizeStorage: Bool,
    compressionLevel: String,
    cliBinaryPath: () -> URL? = { CLIImportRunner.cliBinaryPath() }
) throws {
    try writeGUISRAFASTQImportProvenance(
        accession: accession,
        readRecord: readRecord,
        downloadSource: downloadSource,
        preferredSource: preferredSource,
        layoutWarning: layoutWarning,
        fallbackMessage: fallbackMessage,
        enaDownloadSteps: enaDownloadSteps,
        toolkitDownloadTraces: toolkitDownloadTraces,
        cliArguments: cliArguments,
        cliCommandLine: CLIImportRunner.commandLine(arguments: cliArguments),
        cliStartedAt: cliStartedAt,
        cliCompletedAt: cliCompletedAt,
        stagedFASTQFiles: stagedFASTQFiles,
        stagedReadCounts: stagedReadCounts,
        finalFASTQURL: finalFASTQURL,
        bundleURL: bundleURL,
        platform: platform,
        recipeName: recipeName,
        qualityBinning: qualityBinning,
        optimizeStorage: optimizeStorage,
        compressionLevel: compressionLevel,
        cliBinaryPath: cliBinaryPath
    )
}
