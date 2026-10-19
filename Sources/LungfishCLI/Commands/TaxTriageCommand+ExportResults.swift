// TaxTriageCommand+ExportResults.swift - lungfish-cli taxtriage export results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension TaxTriageCommand {
    /// Writes the results table the app's TaxTriage viewer exports as CSV or TSV, with its record beside it.
    ///
    /// The leaf reads the result folder's `taxtriage.sqlite`, the run's `taxtriage-result.json` when it exists, which
    /// holds the negative controls, and, when a metadata column is written, filtered or sorted by, the sample
    /// metadata table and its edit journal under `metadata/`. It names only those files as inputs (BIO 6). It writes
    /// the rows of the samples given (every sample without `--sample`) that match `--search`, keeps the rows the
    /// column filters keep, and orders them by the one `--sort` key it takes, as the viewer's flat table does. Unique Reads
    /// holds the count the database stores and is empty where it stores none (BIO ruling on 12.32, F3). No result
    /// opens in another table mode, so the leaf takes no `--mode` (F1).
    struct ExportResultsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "results",
            abstract: "Write the results table as CSV or TSV"
        )

        @Argument(help: "The TaxTriage result folder the app opens, which holds taxtriage.sqlite")
        var resultPath: String

        @OptionGroup var samples: ViewerExportOptions.Samples
        @OptionGroup var search: ViewerExportOptions.Search
        @OptionGroup var sort: ViewerExportOptions.Sort
        @OptionGroup var filters: ViewerExportOptions.Filters
        @OptionGroup var metadataColumns: ViewerExportOptions.MetadataColumns
        @OptionGroup var format: ViewerExportOptions.ExportFormat<ViewerExportDelimitedFormat>
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
            return TaxTriageResultsExport.invocation(
                resultURL: URL(fileURLWithPath: resultPath, isDirectory: true),
                samples: state.samples,
                searchText: state.searchText,
                sortKeys: state.sortKeys,
                filters: state.filters,
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
                startMessage: "Exporting the TaxTriage results table."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let state = invocation.state
            guard state.sortKeys.count <= 1 else {
                throw ViewerExportRefusal(
                    "The results table orders by one sort key, the first. Give one --sort, not \(state.sortKeys.count)."
                )
            }
            let resultURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
            let outputURL = URL(fileURLWithPath: invocation.output)
            let metadataInputs = EsVirituDetectionExport.metadataInputURLs(
                in: resultURL,
                writesMetadata: Self.readsMetadata(state)
            )
            let source = try TaxTriageCommand.loadExportSource(
                invocation: invocation,
                requiresSidecar: false,
                extraInputs: metadataInputs
            )
            let store = try Self.metadataStore(resultURL: resultURL, state: state, sampleIds: source.sampleIds)
            try Self.refuseUnknownSortColumn(state, store: store)

            let rows = TaxTriageResultsExport.shownRows(
                metrics: source.metrics,
                filters: state.filters,
                sortKeys: state.sortKeys,
                totalReadsByKey: source.totalReadsByKey,
                uniqueReadsByKey: source.uniqueReadsByKey,
                contaminationRiskOrganismKeys: source.contaminationRiskOrganismKeys,
                metadata: store
            )
            let metadata = EsVirituDetectionExport.metadataTable(
                store: store,
                visibleColumns: Set(state.metadataColumns),
                sampleIds: Set(rows.compactMap(\.sample))
            )
            let content = TaxTriageResultsExport.buildDelimitedExport(
                rows: rows,
                totalReadsByKey: source.totalReadsByKey,
                uniqueReadsByKey: source.uniqueReadsByKey,
                contaminationRiskOrganismKeys: source.contaminationRiskOrganismKeys,
                metadataHeaders: metadata.headers,
                metadataValuesBySample: metadata.valuesBySample,
                separator: format.format.separator
            )

            var explicitOptions: [String: ParameterValue] = ["outputFormat": .string(format.format.rawValue)]
            if !state.sortKeys.isEmpty {
                explicitOptions["sortKeys"] = .array(state.sortKeys.map { ParameterValue.string($0.argument) })
            }
            if !state.filters.filters.isEmpty {
                explicitOptions["filters"] = .array(
                    state.filters.filters.map { ParameterValue.string(ViewerTableExportState.encodedFilter($0)) }
                )
                explicitOptions["filterMatch"] = .string(state.filters.composition.rawValue)
            }
            if !state.metadataColumns.isEmpty {
                explicitOptions["metadataColumns"] = .array(state.metadataColumns.map(ParameterValue.string))
            }
            let sortDescriptors: [ParameterValue] = state.sortKeys.map { key in
                .dictionary([
                    "key": .string(key.column),
                    "ascending": .boolean(key.ascending),
                    "selector": .string("compare:"),
                ])
            }
            let noun = rows.count == 1 ? "row" : "rows"
            return try TaxTriageCommand.writeExport(
                workflowName: TaxTriageResultsExport.workflowName,
                invocation: invocation,
                source: source,
                content: content,
                resolved: [
                    "rowCount": .integer(rows.count),
                    "sampleIds": .array(source.sampleIds.map(ParameterValue.string)),
                    "selectedSamples": .array(source.selectedSamples.map(ParameterValue.string)),
                    "organismSearchText": .string(state.searchText ?? ""),
                    "tableMode": .string(TaxTriageExportLoader.tableModeName),
                    "sortDescriptors": .array(sortDescriptors),
                    "metadataColumns": .array(metadata.headers.map(ParameterValue.string)),
                ],
                runClock: runClock,
                message: "Exported \(rows.count) \(noun) to \(outputURL.lastPathComponent)",
                extraExplicit: explicitOptions,
                extraInputs: metadataInputs
            )
        }

        /// Whether the export reads the sample metadata store, which it does for a metadata column it writes, a
        /// filter on one and a sort by one.
        static func readsMetadata(_ state: ViewerTableExportState) -> Bool {
            let prefix = TaxTriageResultsExport.metadataColumnPrefix
            return !state.metadataColumns.isEmpty
                || state.filters.activeFilters.contains { $0.columnId.hasPrefix(prefix) }
                || state.sortKeys.first?.column.hasPrefix(prefix) == true
        }

        /// The store the app loads from the result folder, or nil when the export reads none. It refuses a store
        /// that is missing and a metadata column the store does not hold.
        private static func metadataStore(
            resultURL: URL,
            state: ViewerTableExportState,
            sampleIds: [String]
        ) throws -> SampleMetadataStore? {
            guard readsMetadata(state) else { return nil }
            guard let store = SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(sampleIds)) else {
                throw ViewerExportRefusal(
                    "The metadata columns, filters and sort named need the sample metadata table at "
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

        /// Refuses a primary sort key that names no column of the table.
        private static func refuseUnknownSortColumn(
            _ state: ViewerTableExportState,
            store: SampleMetadataStore?
        ) throws {
            guard let column = state.sortKeys.first?.column else { return }
            if TaxTriageResultsExport.columnIds.contains(column) { return }
            let prefix = TaxTriageResultsExport.metadataColumnPrefix
            if column.hasPrefix(prefix), store?.columnNames.contains(String(column.dropFirst(prefix.count))) == true {
                return
            }
            throw ViewerExportRefusal(
                "No column \(column) to sort by. The columns are \(TaxTriageResultsExport.columnIds.joined(separator: ", ")) "
                    + "and a metadata column as \(prefix)<name>."
            )
        }
    }
}
