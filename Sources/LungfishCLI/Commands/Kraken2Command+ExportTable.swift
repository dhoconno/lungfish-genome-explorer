// Kraken2Command+ExportTable.swift - lungfish-cli kraken2 export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension Kraken2Command {
    /// The exports of a Kraken2 result (Phase 2.12 lane 12.33, ARCH ruling X-1).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export Kraken2 result tables with provenance",
            subcommands: [
                ExportTableSubcommand.self,
            ]
        )
    }

    /// Writes the taxonomy table the app's Kraken2 viewer exports, with its record beside it.
    ///
    /// The source is the file the viewer's tree came from (ARCH ruling on 12.33 F1). `kraken2.sqlite` holds every
    /// sample of a batch or an indexed result, and `--sample` picks among them (none is every sample). One sample is
    /// its own table. More are a Root row and then one block for each sample, which reads as that sample's own table
    /// with its own unclassified row (BIO-R1 items 1 and 3, Phase 2.13 lane 13.35). `classification-result.json`
    /// holds the one sample of a run, and the leaf rebuilds its tree from the sidecar, the report and the Bracken
    /// file. A folder selects by the sidebar's rule. The record names exactly the files the leaf read, each with its
    /// digest (BIO 6). The app's Export runs this leaf behind its Operations row.
    struct ExportTableSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "table",
            abstract: "Write the taxonomy table of a Kraken2 result as TSV or CSV with provenance"
        )

        @Argument(help: "The Kraken2 result the app shows. Pass kraken2.sqlite, classification-result.json or the result folder")
        var sourcePath: String

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
            return Kraken2TaxonomyTableExport.invocation(
                sourceURL: URL(fileURLWithPath: sourcePath),
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
                startMessage: "Exporting the Kraken2 taxonomy table."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let outputURL = URL(fileURLWithPath: invocation.output)
            guard let source = Kraken2TaxonomyTableExport.Source(url: URL(fileURLWithPath: invocation.input)) else {
                throw ViewerExportRefusal(
                    "No Kraken2 result at \(invocation.input). Pass kraken2.sqlite, classification-result.json "
                        + "or the result folder the app opens."
                )
            }
            let resultURL = source.folderURL
            try ViewerExportLeaf.refuseUnsafeOutput(
                outputURL,
                inputs: [source.fileURL]
                    + Kraken2TaxonomyTableExport.metadataInputURLs(in: resultURL, writesMetadata: true),
                force: invocation.force
            )

            let loaded = try load(source, samples: invocation.state.samples)
            try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: loaded.inputs, force: invocation.force)
            let metadata = try metadataTable(
                resultURL: resultURL,
                columns: invocation.state.metadataColumns,
                knownSampleIds: loaded.known,
                sampleIds: loaded.selected
            )
            let content = Kraken2TaxonomyTableExport.buildDelimitedExport(
                sampleTrees: loaded.trees,
                separator: format.format.separator,
                metadataHeaders: metadata.headers,
                metadataValuesBySample: metadata.valuesBySample
            )
            let sourceURLs = (loaded.inputs + Kraken2TaxonomyTableExport.metadataInputURLs(
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
            let nodeCount = loaded.tree.allNodes().count
            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: Kraken2TaxonomyTableExport.workflowName,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions,
                resolved: [
                    "nodeCount": .integer(nodeCount),
                    "outputByteCount": .integer(content.utf8.count),
                    "selectedSamples": .array(loaded.selected.map(ParameterValue.string)),
                ],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = nodeCount == 1 ? "taxon" : "taxa"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported \(nodeCount) \(noun) to \(outputURL.lastPathComponent)"
            )
        }

        /// The tree the viewer shows for the source, each picked sample's own tree (which the table is written from),
        /// the sample ids it holds, every sample id the source records (which the metadata table is keyed by) and the
        /// files the leaf opened for the tree.
        private func load(
            _ source: Kraken2TaxonomyTableExport.Source,
            samples requested: [String]
        ) throws -> (
            tree: TaxonTree, trees: [(sampleId: String, tree: TaxonTree)], selected: [String], known: [String],
            inputs: [URL]
        ) {
            switch source {
            case .database(let databaseURL):
                let database: Kraken2Database
                do {
                    database = try Kraken2Database(at: databaseURL)
                } catch {
                    throw ViewerExportRefusal("The Kraken2 database at \(databaseURL.path) cannot be read. \(error)")
                }
                if database.needsRebuild {
                    // BIO-R1 items 7 and 8 (Phase 2.13 lane 13.35). A database of the older builder may hold
                    // Bracken's estimates under headers that name Kraken2's reads. The leaf never rebuilds it, since
                    // that would change the input its record names by digest, and the reports only choose the message.
                    let closing = Kraken2TaxonomyTableExport.reportsAvailable(in: databaseURL.deletingLastPathComponent())
                        ? "Open the result in Lungfish to rebuild it from its reports, then export again."
                        : "Its reports are gone, so it cannot be rebuilt or exported."
                    throw ViewerExportRefusal(
                        "The Kraken2 database at \(databaseURL.path) was built by an older version of Lungfish and may hold "
                            + "Bracken's estimates in place of Kraken2's read counts. \(closing)"
                    )
                }
                let known = try database.fetchSamples().map(\.sample).sorted()
                let unknown = requested.filter { !known.contains($0) }
                guard unknown.isEmpty else {
                    throw ViewerExportRefusal(
                        "No sample \(unknown.joined(separator: ", ")) in \(databaseURL.path). "
                            + "Pass --sample with an id the database records."
                    )
                }
                let selected = requested.isEmpty ? known : Array(Set(requested)).sorted()
                let trees = try selected.map { (sampleId: $0, tree: try database.fetchTree(sample: $0)) }
                guard let tree = Kraken2TaxonomyTableExport.displayTree(for: trees) else {
                    throw ViewerExportRefusal("The Kraken2 database at \(databaseURL.path) holds no samples.")
                }
                return (tree, trees, selected, known, [databaseURL])
            case .sidecar(let sidecarURL):
                guard requested.isEmpty else {
                    throw ViewerExportRefusal(
                        "--sample applies to kraken2.sqlite. \(sidecarURL.path) holds the one sample of a run."
                    )
                }
                let folder = sidecarURL.deletingLastPathComponent()
                let result: ClassificationResult
                do {
                    result = try ClassificationResult.load(from: folder)
                } catch {
                    throw ViewerExportRefusal("The Kraken2 result at \(folder.path) cannot be read. \(error)")
                }
                let sampleId = Kraken2TaxonomyTableExport.sidecarSampleId(config: result.config)
                return (
                    result.tree, [(sampleId: sampleId, tree: result.tree)], [sampleId], [sampleId],
                    Kraken2TaxonomyTableExport.sidecarInputURLs(folder: folder, result: result)
                )
            }
        }

        /// The metadata columns asked for, in the store's order, with each sample's values. The store is the one the
        /// app loads from the result folder.
        private func metadataTable(
            resultURL: URL,
            columns: [String],
            knownSampleIds: [String],
            sampleIds: [String]
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
            return Kraken2TaxonomyTableExport.metadataTable(
                store: store,
                visibleColumns: Set(columns),
                sampleIds: sampleIds
            )
        }
    }
}
