// BlastCommand+ExportTable.swift - lungfish-cli blast export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension BlastCommand {
    /// The exports of a saved BLAST search (Phase 2.12 lane 12.33, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export BLAST result tables with provenance",
            subcommands: [
                ExportTableSubcommand.self,
            ]
        )
    }

    /// Writes the table the app's BLAST drawer exports, with its record beside it.
    ///
    /// The input is the file the drawer's result was read from (ARCH ruling T5 of lane 12.33). That is the
    /// `blast-result.json` of a `blast submit` folder or a ``BlastVerificationArchive`` file. The leaf decodes the
    /// submit record first and the archive only when that fails, because an archive record needs only a version,
    /// a date and a result, so it would also decode a submit record. The rows are the hits of the file's result, one
    /// row per hit, built by ``BlastVerificationTableExport/tableContent(result:separator:)``, which the drawer's
    /// writer for a result with no file shares. The record names the one file the leaf read with its digest and
    /// resolves the taxon, the search and which of the two forms the file is (BIO 6).
    struct ExportTableSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "table",
            abstract: "Write the hit table of a saved BLAST search as TSV or CSV with provenance"
        )

        @Argument(help: "The saved BLAST search the drawer shows. Pass the blast-result.json of a blast submit folder or a BLAST verification archive file")
        var recordPath: String

        @OptionGroup var format: ViewerExportOptions.ExportFormat<ViewerExportDelimitedFormat>
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() -> ViewerExportInvocation {
            BlastVerificationTableExport.invocation(
                recordURL: URL(fileURLWithPath: recordPath),
                format: format.format,
                outputURL: URL(fileURLWithPath: output.path),
                force: output.force,
                emitsEvents: globalOptions.outputFormat == .json
            )
        }

        func run() async throws {
            let command = self
            try await ViewerExportLeaf.run(
                globalOptions: globalOptions,
                startMessage: "Exporting the BLAST table."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = invocation()
            let recordURL = URL(fileURLWithPath: invocation.input)
            let outputURL = URL(fileURLWithPath: invocation.output)
            try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [recordURL], force: invocation.force)
            let loaded = try Self.load(recordURL)
            let result = loaded.result
            let content = BlastVerificationTableExport.tableContent(result: result, separator: format.format.separator)

            var explicitOptions: [String: ParameterValue] = [
                "outputPath": .file(outputURL),
                "outputFormat": .string(format.format.rawValue),
            ]
            if invocation.force {
                explicitOptions["force"] = .boolean(true)
            }
            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: BlastVerificationTableExport.workflowName,
                sourceURLs: [recordURL],
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions,
                resolved: [
                    "database": .string(result.database),
                    "inputKind": .string(loaded.kind),
                    "outputByteCount": .integer(content.utf8.count),
                    "program": .string(result.blastProgram),
                    "rid": .string(result.rid),
                    "taxId": .integer(result.taxId),
                    "taxonName": .string(result.taxonName),
                    "totalReads": .integer(result.totalReads),
                ],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = result.totalReads == 1 ? "read" : "reads"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported the hits of \(result.totalReads) \(noun) to \(outputURL.lastPathComponent)"
            )
        }

        /// The result the file holds, and which of the two forms the file is. The submit record is decoded first.
        static func load(_ url: URL) throws -> (result: BlastVerificationResult, kind: String) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ViewerExportRefusal(
                    "No saved BLAST search at \(url.path). Pass the blast-result.json of a blast submit folder "
                        + "or a BLAST verification archive file."
                )
            }
            if let record = try? BlastSubmissionRecord.load(url) {
                return (record.result, "blast-submit-record")
            }
            if let archived = try? BlastVerificationArchive.load(url) {
                return (archived.result, "blast-verification-archive")
            }
            throw ViewerExportRefusal(
                "\(url.path) is neither a blast submit record (blast-result.json) nor a BLAST verification archive "
                    + "file. Pass the file the BLAST drawer shows."
            )
        }
    }
}
