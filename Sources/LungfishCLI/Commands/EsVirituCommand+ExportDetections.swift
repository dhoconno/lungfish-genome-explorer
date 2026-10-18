// EsVirituCommand+ExportDetections.swift - lungfish-cli esviritu export detections
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension EsVirituCommand {
    /// The exports of an EsViritu result (Phase 2.12 lane 12.31, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export EsViritu result tables with provenance",
            subcommands: [
                ExportDetectionsSubcommand.self,
            ]
        )
    }

    /// Writes the detection table the app's EsViritu viewer exports, with its record beside it.
    ///
    /// The leaf reads the result folder's `esviritu.sqlite` and, for `--metadata-column`, the sample metadata table
    /// and its edit journal under `metadata/`, and names only those files as inputs (BIO 6). It writes every
    /// detection of the samples given in the viewer's order, each row with its own sample's metadata values (BIO
    /// ruling on 12.31 G1). The app's Export runs this leaf behind its Operations row.
    struct ExportDetectionsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detections",
            abstract: "Write the detection table of an EsViritu result as TSV or CSV with provenance"
        )

        @Argument(help: "The EsViritu result folder the app opens, which holds esviritu.sqlite")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var metadataColumns: ViewerExportOptions.MetadataColumns
        @OptionGroup var format: ViewerExportOptions.ExportFormat<ViewerExportDelimitedFormat>
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            try samples.apply(to: &state)
            try metadataColumns.apply(to: &state)
            return EsVirituDetectionExport.invocation(
                resultURL: URL(fileURLWithPath: resultPath, isDirectory: true),
                samples: state.samples,
                metadataColumns: state.metadataColumns,
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
                startMessage: "Exporting EsViritu detections."
            ) {
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let resultURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
            let outputURL = URL(fileURLWithPath: invocation.output)
            let databaseURL = resultURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName)
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw ViewerExportRefusal(
                    "No EsViritu database at \(databaseURL.path). Pass the EsViritu result folder the app opens."
                )
            }
            try ViewerExportLeaf.refuseExistingOutput(outputURL, force: invocation.force)

            let database: EsVirituDatabase
            do {
                database = try EsVirituDatabase(at: databaseURL)
            } catch {
                throw ViewerExportRefusal("The EsViritu database at \(databaseURL.path) cannot be read. \(error)")
            }
            let allSamples = try database.fetchSamples().map(\.sample).sorted()
            let unknownSamples = invocation.state.samples.filter { !allSamples.contains($0) }
            guard unknownSamples.isEmpty else {
                throw ViewerExportRefusal(
                    "No sample \(unknownSamples.joined(separator: ", ")) in \(databaseURL.path). "
                        + "Pass --sample with an id the result records."
                )
            }
            let selected = invocation.state.samples.isEmpty
                ? allSamples
                : Array(Set(invocation.state.samples)).sorted()
            let rows = try database.fetchRows(samples: allSamples)
            let result = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: selected)
            let metadata = try metadataTable(
                resultURL: resultURL,
                columns: invocation.state.metadataColumns,
                knownSampleIds: allSamples,
                detections: result.detections
            )
            let content = EsVirituDetectionExport.buildDelimitedExport(
                result: result,
                separator: format.format.separator,
                metadataHeaders: metadata.headers,
                metadataValuesBySample: metadata.valuesBySample
            )
            let sourceURLs = ([databaseURL] + EsVirituDetectionExport.metadataInputURLs(
                in: resultURL,
                writesMetadata: !metadata.headers.isEmpty
            )).filter { FileManager.default.fileExists(atPath: $0.path) }

            var explicitOptions: [String: ParameterValue] = [
                "outputPath": .file(outputURL),
                "outputFormat": .string(format.format.rawValue),
            ]
            if !invocation.state.samples.isEmpty {
                explicitOptions["samples"] = .array(invocation.state.samples.map(ParameterValue.string))
            }
            if !invocation.state.metadataColumns.isEmpty {
                explicitOptions["metadataColumns"] = .array(invocation.state.metadataColumns.map(ParameterValue.string))
            }
            if invocation.force {
                explicitOptions["force"] = .boolean(true)
            }
            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: EsVirituDetectionExport.workflowName,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions,
                resolved: [
                    "rowCount": .integer(result.detections.count),
                    "sampleId": .string(result.sampleId),
                    "selectedSamples": .array(selected.map(ParameterValue.string)),
                    "sourceSampleCount": .integer(allSamples.count),
                    "tableMode": .string("batchHierarchical"),
                    "metadataColumns": .array(metadata.headers.map(ParameterValue.string)),
                ],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = result.detections.count == 1 ? "detection" : "detections"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported \(result.detections.count) \(noun) to \(outputURL.lastPathComponent)"
            )
        }

        /// The metadata columns asked for, in the store's order, with each detection sample's values. The store is
        /// the one the app loads, keyed by every sample of the database.
        private func metadataTable(
            resultURL: URL,
            columns: [String],
            knownSampleIds: [String],
            detections: [ViralDetection]
        ) throws -> (headers: [String], valuesBySample: [String: [String]]) {
            guard !columns.isEmpty else { return ([], [:]) }
            guard let store = SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(knownSampleIds)) else {
                throw ViewerExportRefusal(
                    "--metadata-column needs the sample metadata table at "
                        + "\(resultURL.appendingPathComponent("metadata/sample_metadata.tsv").path), "
                        + "which is missing or cannot be read."
                )
            }
            let unknownColumns = columns.filter { !store.columnNames.contains($0) }
            guard unknownColumns.isEmpty else {
                throw ViewerExportRefusal(
                    "No metadata column \(unknownColumns.joined(separator: ", ")) in the result's sample metadata. "
                        + "The columns are \(store.columnNames.joined(separator: ", "))."
                )
            }
            return EsVirituDetectionExport.metadataTable(
                store: store,
                visibleColumns: Set(columns),
                sampleIds: Set(detections.map(\.sampleId))
            )
        }
    }
}
