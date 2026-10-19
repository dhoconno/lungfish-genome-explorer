// TaxTriageCommand+Export.swift - lungfish-cli taxtriage export organism-matrix and batch-report
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension TaxTriageCommand {
    /// The exports of a TaxTriage result (Phase 2.12 lane 12.32, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export TaxTriage result tables with provenance",
            subcommands: [
                ExportOrganismMatrixSubcommand.self,
                ExportBatchReportSubcommand.self,
                ExportResultsSubcommand.self,
            ]
        )
    }

    /// Writes the cross-sample organism matrix the app's TaxTriage viewer exports, with its record beside it.
    ///
    /// The leaf reads the result folder's `taxtriage.sqlite` and, when it exists, the run's `taxtriage-result.json`,
    /// which holds the negative controls, and names only those files as inputs (BIO 6). It reads the rows of the
    /// samples given (every sample without `--sample`) that match `--search`, as the viewer's Sample Filter and
    /// organism search do. The flat table's sort and column filters never reach the matrix, so the leaf takes
    /// neither, and no result opens in another table mode, so it takes no `--mode` (BIO ruling on 12.32, F1).
    struct ExportOrganismMatrixSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "organism-matrix",
            abstract: "Write the cross-sample organism matrix of a TaxTriage result as CSV with provenance"
        )

        @Argument(help: "The TaxTriage result folder the app opens, which holds taxtriage.sqlite")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var search: ViewerExportOptions.Search
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            try samples.apply(to: &state)
            try search.apply(to: &state)
            return TaxTriageOrganismMatrixExport.invocation(
                resultURL: URL(fileURLWithPath: resultPath, isDirectory: true),
                samples: state.samples,
                searchText: state.searchText,
                outputURL: URL(fileURLWithPath: output.path),
                force: output.force,
                emitsEvents: globalOptions.outputFormat == .json
            )
        }

        func run() async throws {
            let command = self
            try await ViewerExportLeaf.run(
                globalOptions: globalOptions,
                startMessage: "Exporting the TaxTriage organism matrix."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let source = try TaxTriageCommand.loadExportSource(invocation: invocation, requiresSidecar: false)
            let content = TaxTriageBatchExporter.generateOrganismMatrixCSV(
                metrics: source.metrics,
                sampleIds: source.sampleIds,
                negativeControlSampleIds: source.negativeControlSampleIds
            )
            let organisms = source.crossSampleOrganismCount
            let noun = organisms == 1 ? "organism" : "organisms"
            return try TaxTriageCommand.writeExport(
                workflowName: TaxTriageOrganismMatrixExport.workflowName,
                invocation: invocation,
                source: source,
                content: content,
                resolved: [
                    "rowCount": .integer(organisms),
                    "exportedOrganismCount": .integer(organisms),
                    "metricCount": .integer(source.metrics.count),
                    "sampleCount": .integer(source.sampleIds.count),
                    "sampleIds": .array(source.sampleIds.map(ParameterValue.string)),
                    "negativeControlSampleIds": .array(
                        source.negativeControlSampleIds.sorted().map(ParameterValue.string)
                    ),
                    "tableMode": .string(TaxTriageExportLoader.tableModeName),
                ],
                runClock: runClock,
                message: "Exported \(organisms) \(noun) to \(URL(fileURLWithPath: invocation.output).lastPathComponent)"
            )
        }
    }

    /// Writes the batch report text the app's TaxTriage viewer exports, with its record beside it.
    ///
    /// The report needs the run's sidecar, which holds the platform, runtime and exit code, as the viewer's menu
    /// item needs it. Its `Date:` line holds the clock of the run that writes it. Like the matrix, it follows the
    /// samples given and `--search`, and no sort or filter.
    struct ExportBatchReportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "batch-report",
            abstract: "Write the batch report of a TaxTriage result as text with provenance"
        )

        @Argument(help: "The TaxTriage result folder the app opens, which holds taxtriage.sqlite and taxtriage-result.json")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var search: ViewerExportOptions.Search
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            try samples.apply(to: &state)
            try search.apply(to: &state)
            return TaxTriageBatchReportExport.invocation(
                resultURL: URL(fileURLWithPath: resultPath, isDirectory: true),
                samples: state.samples,
                searchText: state.searchText,
                outputURL: URL(fileURLWithPath: output.path),
                force: output.force,
                emitsEvents: globalOptions.outputFormat == .json
            )
        }

        func run() async throws {
            let command = self
            try await ViewerExportLeaf.run(
                globalOptions: globalOptions,
                startMessage: "Exporting the TaxTriage batch report."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let source = try TaxTriageCommand.loadExportSource(invocation: invocation, requiresSidecar: true)
            guard let result = source.result else {
                throw ViewerExportRefusal("The batch report needs the run's sidecar, which the result folder lacks.")
            }
            let report = TaxTriageBatchExporter.generateSummaryReport(
                result: result,
                config: result.config,
                metrics: source.metrics,
                sampleIds: source.sampleIds
            )
            let reportLineCount = report.split(separator: "\n", omittingEmptySubsequences: false).count
            return try TaxTriageCommand.writeExport(
                workflowName: TaxTriageBatchReportExport.workflowName,
                invocation: invocation,
                source: source,
                content: report,
                resolved: [
                    "reportLineCount": .integer(reportLineCount),
                    "metricCount": .integer(source.metrics.count),
                    "sampleCount": .integer(source.sampleIds.count),
                    "exportedOrganismCount": .integer(source.crossSampleOrganismCount),
                    "sampleIds": .array(source.sampleIds.map(ParameterValue.string)),
                    "negativeControlSampleIds": .array(
                        source.negativeControlSampleIds.sorted().map(ParameterValue.string)
                    ),
                    "classifierCount": .integer(result.config.classifiers.count),
                    "tableMode": .string(TaxTriageExportLoader.tableModeName),
                ],
                runClock: runClock,
                message: "Exported the batch report to \(URL(fileURLWithPath: invocation.output).lastPathComponent)"
            )
        }
    }

    /// Refuses before reading anything, then reads the result folder the invocation names. Every refusal comes
    /// before a byte is written.
    static func loadExportSource(
        invocation: ViewerExportInvocation,
        requiresSidecar: Bool,
        extraInputs: [URL] = []
    ) throws -> TaxTriageExportSource {
        let resultURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
        let outputURL = URL(fileURLWithPath: invocation.output)
        let databaseURL = resultURL.appendingPathComponent(TaxTriageExportLoader.databaseFileName)
        let sidecarURL = resultURL.appendingPathComponent(TaxTriageExportLoader.sidecarFileName)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ViewerExportRefusal(
                "No TaxTriage database at \(databaseURL.path). Pass the TaxTriage result folder the app opens."
            )
        }
        if requiresSidecar, !FileManager.default.fileExists(atPath: sidecarURL.path) {
            throw ViewerExportRefusal(
                "The batch report needs the run's sidecar at \(sidecarURL.path), which is missing."
            )
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [databaseURL, sidecarURL] + extraInputs, force: invocation.force)
        do {
            return try TaxTriageExportLoader.load(
                resultURL: resultURL,
                samples: invocation.state.samples,
                searchText: invocation.state.searchText
            )
        } catch let error as TaxTriageExportLoader.LoadError {
            throw ViewerExportRefusal(error.localizedDescription)
        }
    }

    /// Writes `content` and its record in one transaction. The record names the leaf, its canonical argv and the
    /// files the export read, each with its digest.
    static func writeExport(
        workflowName: String,
        invocation: ViewerExportInvocation,
        source: TaxTriageExportSource,
        content: String,
        resolved: [String: ParameterValue],
        runClock: ProvenanceRunClock,
        message: String,
        extraExplicit: [String: ParameterValue] = [:],
        extraInputs: [URL] = []
    ) throws -> ViewerExportLeafOutcome {
        let outputURL = URL(fileURLWithPath: invocation.output)
        var explicitOptions: [String: ParameterValue] = ["outputPath": .file(outputURL)]
        if !invocation.state.samples.isEmpty {
            explicitOptions["samples"] = .array(invocation.state.samples.map(ParameterValue.string))
        }
        if let searchText = invocation.state.searchText {
            explicitOptions["searchText"] = .string(searchText)
        }
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        explicitOptions.merge(extraExplicit) { _, new in new }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: workflowName,
            sourceURLs: source.inputURLs + extraInputs.filter { FileManager.default.fileExists(atPath: $0.path) },
            outputURL: outputURL,
            outputFormat: .text,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            resolved: resolved,
            runClock: runClock
        )) { stagedURL in
            try content.write(to: stagedURL, atomically: true, encoding: .utf8)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        return ViewerExportLeafOutcome(outputURL: outputURL, message: message)
    }
}
