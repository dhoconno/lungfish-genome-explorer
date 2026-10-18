// NvdCommand+ExportContigs.swift - lungfish-cli nvd export contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension NvdCommand {
    /// The exports of an NVD result (Phase 2.12 lane 12.31, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export NVD result tables with provenance",
            subcommands: [
                ExportContigsSubcommand.self,
            ]
        )
    }

    /// Writes the contigs table the app's NVD viewer exports, with its record beside it.
    ///
    /// The leaf reads the result folder's `hits.sqlite` and `manifest.json` and, when a metadata column is written,
    /// the sample metadata table and its edit journal under `metadata/`, and names only those files as inputs, never
    /// the run folder the import read (BIO ruling on 12.31 M4). It writes the best hit of each contig of the samples
    /// given, or of those the search matches, in the database's order, each row with its own sample's metadata
    /// values. The app's Export runs this leaf behind its Operations row.
    struct ExportContigsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "contigs",
            abstract: "Write the contigs table of an NVD result as TSV with provenance"
        )

        @Argument(help: "The NVD result folder the app opens, which holds hits.sqlite and manifest.json")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var search: ViewerExportOptions.Search
        @OptionGroup var metadataColumns: ViewerExportOptions.MetadataColumns
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            try samples.apply(to: &state)
            try search.apply(to: &state)
            try metadataColumns.apply(to: &state)
            return NvdContigsExport.invocation(
                resultURL: URL(fileURLWithPath: resultPath, isDirectory: true),
                state: state,
                outputURL: URL(fileURLWithPath: output.path),
                force: output.force,
                emitsEvents: globalOptions.outputFormat == .json
            )
        }

        func run() async throws {
            let command = self
            try await ViewerExportLeaf.run(
                globalOptions: globalOptions,
                startMessage: "Exporting the NVD contigs."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let state = invocation.state
            let resultURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
            let outputURL = URL(fileURLWithPath: invocation.output)
            let databaseURL = resultURL.appendingPathComponent(NvdContigsExport.databaseFileName)
            let manifestURL = resultURL.appendingPathComponent(NvdContigsExport.manifestFileName)
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw ViewerExportRefusal(
                    "No NVD database at \(databaseURL.path). Pass the NVD result folder the app opens."
                )
            }
            try ViewerExportLeaf.refuseUnsafeOutput(
                outputURL,
                inputs: [databaseURL, manifestURL]
                    + EsVirituDetectionExport.metadataInputURLs(in: resultURL, writesMetadata: true),
                force: invocation.force
            )

            let manifest: NvdManifest
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                manifest = try decoder.decode(NvdManifest.self, from: Data(contentsOf: manifestURL))
            } catch {
                throw ViewerExportRefusal("The NVD manifest at \(manifestURL.path) cannot be read. \(error)")
            }
            let database: NvdDatabase
            do {
                database = try NvdDatabase(at: databaseURL)
            } catch {
                throw ViewerExportRefusal("The NVD database at \(databaseURL.path) cannot be read. \(error)")
            }
            let allSamples = try database.allSamples().map(\.sampleId).sorted()
            let unknownSamples = state.samples.filter { !allSamples.contains($0) }
            guard unknownSamples.isEmpty else {
                throw ViewerExportRefusal(
                    "No sample \(unknownSamples.joined(separator: ", ")) in \(databaseURL.path). "
                        + "Pass --sample with an id the result records."
                )
            }
            let selected = state.samples.isEmpty ? allSamples : Array(Set(state.samples)).sorted()
            let query = (state.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hits = try NvdContigsExport.shownHits(in: database, samples: selected, searchText: query)
            let store = try metadataStore(resultURL: resultURL, state: state, knownSampleIds: allSamples)
            let metadata = EsVirituDetectionExport.metadataTable(
                store: store,
                visibleColumns: Set(state.metadataColumns),
                sampleIds: Set(hits.map(\.sampleId))
            )
            let content = NvdContigsExport.contigsTSV(
                hits: hits,
                metadataHeaders: metadata.headers,
                metadataValuesBySample: metadata.valuesBySample
            )
            let sourceURLs = ([databaseURL, manifestURL] + EsVirituDetectionExport.metadataInputURLs(
                in: resultURL,
                writesMetadata: store != nil
            )).filter { FileManager.default.fileExists(atPath: $0.path) }

            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: NvdContigsExport.workflowName,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions(state: state, outputURL: outputURL, force: invocation.force),
                resolved: [
                    "rowCount": .integer(hits.count),
                    "experiment": .string(manifest.experiment),
                    "sourceSampleCount": .integer(allSamples.count),
                    "selectedSamples": .array(selected.map(ParameterValue.string)),
                    "searchQuery": .string(query),
                    "metadataColumns": .array(metadata.headers.map(ParameterValue.string)),
                ],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = hits.count == 1 ? "row" : "rows"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported \(hits.count) \(noun) to \(outputURL.lastPathComponent)"
            )
        }

        /// The result's sample metadata, which the leaf reads only when it writes a metadata column, keyed by every
        /// sample of the database. Nil when no column is asked for.
        private func metadataStore(
            resultURL: URL,
            state: ViewerTableExportState,
            knownSampleIds: [String]
        ) throws -> SampleMetadataStore? {
            guard !state.metadataColumns.isEmpty else { return nil }
            guard let store = SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(knownSampleIds)) else {
                throw ViewerExportRefusal(
                    "--metadata-column needs the sample metadata table at "
                        + "\(resultURL.appendingPathComponent("metadata/sample_metadata.tsv").path), "
                        + "which is missing or cannot be read."
                )
            }
            let unknownColumns = state.metadataColumns.filter { !store.columnNames.contains($0) }
            guard unknownColumns.isEmpty else {
                throw ViewerExportRefusal(
                    "No metadata column \(unknownColumns.joined(separator: ", ")) in the result's sample metadata. "
                        + "The columns are \(store.columnNames.joined(separator: ", "))."
                )
            }
            return store
        }

        private func explicitOptions(
            state: ViewerTableExportState,
            outputURL: URL,
            force: Bool
        ) -> [String: ParameterValue] {
            var options: [String: ParameterValue] = ["outputPath": .file(outputURL)]
            if !state.samples.isEmpty {
                options["samples"] = .array(state.samples.map(ParameterValue.string))
            }
            if let searchText = state.searchText {
                options["searchText"] = .string(searchText)
            }
            if !state.metadataColumns.isEmpty {
                options["metadataColumns"] = .array(state.metadataColumns.map(ParameterValue.string))
            }
            if force {
                options["force"] = .boolean(true)
            }
            return options
        }
    }
}
