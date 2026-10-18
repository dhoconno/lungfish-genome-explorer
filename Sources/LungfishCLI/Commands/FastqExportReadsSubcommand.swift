// FastqExportReadsSubcommand.swift - lungfish-cli fastq export reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes the reads of a FASTQ bundle as one FASTQ file with its record beside it.
///
/// This is the leaf behind the sidebar's Export FASTQ (Phase 2.12 lane 12.38, ARCH ruling 1.1 row B4). A bundle with
/// one FASTQ file is copied, a bundle of several source files is joined in manifest order, and a derived bundle is
/// written as the reads it stands for, which needs `--materialize-derived`. The record names the bundle's FASTQ files
/// (or the folder of a derived bundle) and its two manifests as inputs with their digests. The payload is staged
/// first, then published with the record in one `writeAtomically` transaction, so a refusal, a failure or a cancel
/// leaves no output and no record.
struct FastqExportReadsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Write the reads of a FASTQ bundle as one FASTQ file with provenance",
        discussion: """
            A bundle with one FASTQ file is copied. A bundle of several source files is joined in manifest order, and
            a .gz output joins gzip inputs byte for byte. A derived bundle holds a recipe and no reads, so it needs
            --materialize-derived to write the reads it stands for. The record is written beside the output.

            Examples:
              lungfish-cli fastq export reads Sample.lungfishfastq -o Sample.fastq.gz
              lungfish-cli fastq export reads Subset.lungfishfastq --materialize-derived -o Subset.fastq.gz
            """
    )

    @Argument(help: "The FASTQ bundle (.lungfishfastq) the sidebar shows")
    var bundlePath: String

    @Flag(
        name: .customLong("materialize-derived"),
        help: "Write the reads a derived bundle stands for. A derived bundle needs it"
    )
    var materializeDerived = false

    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        FASTQReadsExport.invocation(
            bundleURL: URL(fileURLWithPath: bundlePath),
            outputURL: URL(fileURLWithPath: output.path),
            isDerived: materializeDerived,
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Exporting the FASTQ reads."
        ) { events in
            try await command.export(events: events)
        }
    }

    /// The export, which refuses before it writes and publishes payload and record in one transaction.
    func export(events: CLIEventEmitter) async throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let bundleURL = URL(fileURLWithPath: invocation.input)
        let outputURL = URL(fileURLWithPath: invocation.output)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ViewerExportRefusal("No FASTQ bundle at \(bundleURL.path). Pass the bundle the sidebar shows.")
        }
        let source: FASTQReadsExport.Source
        do {
            source = try FASTQReadsExport.source(of: bundleURL)
        } catch {
            throw ViewerExportRefusal("\(error.localizedDescription): \(bundleURL.path)")
        }
        if source.isDerived, !materializeDerived {
            throw ViewerExportRefusal(
                "\(bundleURL.lastPathComponent) is a derived bundle that holds a recipe and no reads. "
                    + "Pass --materialize-derived to write the reads it stands for."
            )
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: source.inputURLs, force: invocation.force)

        var explicitOptions: [String: ParameterValue] = ["outputPath": .file(outputURL)]
        if materializeDerived {
            explicitOptions["materializeDerived"] = .boolean(true)
        }
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }

        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).stage")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try Task.checkCancellation()
        try await FASTQReadsExport.write(
            source, to: stagedURL, outputIsGzip: outputURL.isGzipCompressed,
            progress: { message in events.emitProgress(message.hasPrefix("Writing") ? 0.8 : 0.2, message: message) }
        )
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: FASTQReadsExport.workflowName,
            sourceURLs: source.inputURLs,
            outputURL: outputURL,
            outputFormat: .fastq,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            resolved: [
                "isDerived": .boolean(source.isDerived),
                "inputChunkCount": .integer(source.chunkURLs.count),
                "outputGzipCompressed": .boolean(outputURL.isGzipCompressed),
            ],
            runClock: runClock
        )) { tempURL in
            try FileManager.default.moveItem(at: stagedURL, to: tempURL)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        return ViewerExportLeafOutcome(outputURL: outputURL, message: "Exported \(outputURL.lastPathComponent)")
    }
}
