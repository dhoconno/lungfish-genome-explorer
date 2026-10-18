// NaoMgsCommand+ExportTable.swift - lungfish-cli nao-mgs export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension NaoMgsCommand {
    /// The exports of a NAO-MGS result (Phase 2.12 lane 12.31, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export NAO-MGS result tables with provenance",
            subcommands: [
                ExportTableSubcommand.self,
            ]
        )
    }

    /// Writes the taxon table the app's NAO-MGS viewer exports, with its record beside it.
    ///
    /// The leaf reads the result folder's `hits.sqlite` and `manifest.json` and, when a metadata column is written or
    /// a filter reads one, the sample metadata table and its edit journal under `metadata/`, and names only those
    /// files as inputs (BIO ruling on 12.31 M4). It writes the rows of the samples given after the viewer's search,
    /// column filters and first sort key, in the viewer's order, each row with its own sample's metadata values. The
    /// app's Export runs this leaf behind its Operations row.
    struct ExportTableSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "table",
            abstract: "Write the taxon table of a NAO-MGS result as TSV with provenance"
        )

        @Argument(help: "The NAO-MGS result folder the app opens, which holds hits.sqlite and manifest.json")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var search: ViewerExportOptions.Search
        @OptionGroup var sort: ViewerExportOptions.Sort
        @OptionGroup var filters: ViewerExportOptions.Filters
        @OptionGroup var metadataColumns: ViewerExportOptions.MetadataColumns
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            try samples.apply(to: &state)
            try search.apply(to: &state)
            try sort.apply(to: &state)
            try filters.apply(to: &state)
            try metadataColumns.apply(to: &state)
            return NaoMgsSummaryExport.invocation(
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
                startMessage: "Exporting the NAO-MGS table."
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
            let databaseURL = resultURL.appendingPathComponent(NaoMgsSummaryExport.databaseFileName)
            let manifestURL = resultURL.appendingPathComponent(NaoMgsSummaryExport.manifestFileName)
            guard state.sortKeys.count <= 1 else {
                throw ViewerExportRefusal("The NAO-MGS table sorts by one column. Pass --sort once.")
            }
            if let key = state.sortKeys.first, !NaoMgsSummaryExport.sortableColumns.contains(key.column) {
                throw ViewerExportRefusal(
                    "The NAO-MGS table sorts by sample, name, hits, unique or refs, not \(key.column)."
                )
            }
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw ViewerExportRefusal(
                    "No NAO-MGS database at \(databaseURL.path). Pass the NAO-MGS result folder the app opens."
                )
            }
            try ViewerExportLeaf.refuseUnsafeOutput(
                outputURL,
                inputs: [databaseURL, manifestURL]
                    + EsVirituDetectionExport.metadataInputURLs(in: resultURL, writesMetadata: true),
                force: invocation.force
            )

            let manifest: NaoMgsManifest
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                manifest = try decoder.decode(NaoMgsManifest.self, from: Data(contentsOf: manifestURL))
            } catch {
                throw ViewerExportRefusal("The NAO-MGS manifest at \(manifestURL.path) cannot be read. \(error)")
            }
            let database: NaoMgsDatabase
            do {
                database = try NaoMgsDatabase(at: databaseURL)
            } catch {
                throw ViewerExportRefusal("The NAO-MGS database at \(databaseURL.path) cannot be read. \(error)")
            }
            let allSamples = try database.fetchSamples().map(\.sample).sorted()
            let unknownSamples = state.samples.filter { !allSamples.contains($0) }
            guard unknownSamples.isEmpty else {
                throw ViewerExportRefusal(
                    "No sample \(unknownSamples.joined(separator: ", ")) in \(databaseURL.path). "
                        + "Pass --sample with an id the result records."
                )
            }
            let store = try metadataStore(resultURL: resultURL, state: state, knownSampleIds: allSamples)
            let rows = NaoMgsSummaryExport.shownRows(
                try database.fetchTaxonSummaryRows(samples: state.samples),
                searchText: state.searchText ?? "",
                filters: state.filters,
                sortKey: state.sortKeys.first,
                metadataRecords: store?.records ?? [:]
            )
            let selected = state.samples.isEmpty
                ? Array(Set(rows.map(\.sample))).sorted()
                : Array(Set(state.samples)).sorted()
            let metadata = EsVirituDetectionExport.metadataTable(
                store: state.metadataColumns.isEmpty ? nil : store,
                visibleColumns: Set(state.metadataColumns),
                sampleIds: Set(rows.map(\.sample))
            )
            let content = NaoMgsSummaryExport.summaryTSV(
                rows: rows,
                metadataHeaders: metadata.headers,
                metadataValuesBySample: metadata.valuesBySample
            )
            let sourceURLs = ([databaseURL, manifestURL] + EsVirituDetectionExport.metadataInputURLs(
                in: resultURL,
                writesMetadata: store != nil
            )).filter { FileManager.default.fileExists(atPath: $0.path) }

            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: NaoMgsSummaryExport.workflowName,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions(state: state, outputURL: outputURL, force: invocation.force),
                resolved: resolved(
                    state: state,
                    rowCount: rows.count,
                    sampleName: manifest.sampleName,
                    selectedSamples: selected,
                    sourceSampleCount: max(allSamples.count, selected.count),
                    metadataHeaders: metadata.headers
                ),
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = rows.count == 1 ? "row" : "rows"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported \(rows.count) \(noun) to \(outputURL.lastPathComponent)"
            )
        }

        /// The result's sample metadata, which the leaf reads when it writes a metadata column or a filter reads one,
        /// keyed by every sample of the database. Nil when neither needs it, or when only a filter needs it and the
        /// table is absent, as the viewer then has no store.
        private func metadataStore(
            resultURL: URL,
            state: ViewerTableExportState,
            knownSampleIds: [String]
        ) throws -> SampleMetadataStore? {
            let filterReadsMetadata = state.filters.activeFilters.contains { $0.columnId.hasPrefix("metadata_") }
            guard !state.metadataColumns.isEmpty || filterReadsMetadata else { return nil }
            let store = SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(knownSampleIds))
            guard !state.metadataColumns.isEmpty else { return store }
            guard let store else {
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

        /// The applied state and the counts. The filters are the viewer writer's entries. `sortKeys` names the one
        /// key the table applies in its `--sort` spelling, and `searchText` the applied search when there is one.
        private func resolved(
            state: ViewerTableExportState,
            rowCount: Int,
            sampleName: String,
            selectedSamples: [String],
            sourceSampleCount: Int,
            metadataHeaders: [String]
        ) -> [String: ParameterValue] {
            var resolved: [String: ParameterValue] = [
                "rowCount": .integer(rowCount),
                "sampleName": .string(sampleName),
                "selectedSamples": .array(selectedSamples.map(ParameterValue.string)),
                "sourceSampleCount": .integer(sourceSampleCount),
                "columnFilterComposition": .string(state.filters.composition.rawValue),
                "columnFilters": .array(state.filters.activeFilters.map(NaoMgsSummaryExport.columnFilterParameter)),
                "sortKeys": .array(state.sortKeys.map { .string($0.argument) }),
                "metadataColumns": .array(metadataHeaders.map(ParameterValue.string)),
            ]
            if let searchText = state.searchText {
                resolved["searchText"] = .string(searchText)
            }
            return resolved
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
            if !state.sortKeys.isEmpty {
                options["sortKeys"] = .array(state.sortKeys.map { .string($0.argument) })
            }
            if !state.filters.filters.isEmpty {
                options["filters"] = .array(state.filters.filters.map(NaoMgsSummaryExport.columnFilterParameter))
                options["filterMatch"] = .string(state.filters.composition.rawValue)
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
