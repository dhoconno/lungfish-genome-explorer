// VariantsCommand+Export.swift - lungfish-cli variants export bookmarked and variants export sample-template
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension VariantsCommand {
    /// The exports of the variant drawer (Phase 2.12 lane 12.39, ARCH ruling X-1 rows B6 and B11).
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export variant drawer tables with provenance",
            subcommands: [
                ExportBookmarkedSubcommand.self,
                ExportSampleTemplateSubcommand.self,
            ]
        )
    }

    /// Writes the bookmarked variants of variant databases as TSV, with its record beside it.
    ///
    /// The leaf reads the bookmarks each database stores, database by database in the order given, which is the
    /// drawer's track order, and names only those databases as inputs (BIO 6). The drawer's Export Bookmarks runs
    /// this leaf behind its Operations row.
    struct ExportBookmarkedSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bookmarked",
            abstract: "Write the bookmarked variants of variant databases as TSV with provenance"
        )

        @Argument(help: "A variant database the app opens, such as a bundle's variants.db. Repeat for more, in track order")
        var databasePaths: [String]

        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() -> ViewerExportInvocation {
            BookmarkedVariantExport.invocation(
                databaseURLs: databasePaths.map { URL(fileURLWithPath: $0) },
                outputURL: URL(fileURLWithPath: output.path),
                force: output.force,
                emitsEvents: globalOptions.outputFormat == .json
            )
        }

        func run() async throws {
            let command = self
            try await ViewerExportLeaf.run(
                globalOptions: globalOptions,
                startMessage: "Exporting bookmarked variants."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = invocation()
            let databaseURLs = ([invocation.input] + invocation.leafArguments).map { URL(fileURLWithPath: $0) }
            let outputURL = URL(fileURLWithPath: invocation.output)
            for databaseURL in databaseURLs where !FileManager.default.fileExists(atPath: databaseURL.path) {
                throw ViewerExportRefusal("No variant database at \(databaseURL.path). Pass a variant database the app opens.")
            }
            try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: databaseURLs, force: invocation.force)

            var rows: [BookmarkedVariantExport.Row] = []
            for databaseURL in databaseURLs {
                let database: VariantDatabase
                do {
                    database = try VariantDatabase(url: databaseURL)
                } catch {
                    throw ViewerExportRefusal("The variant database at \(databaseURL.path) cannot be read. \(error)")
                }
                rows += database.bookmarkedVariants().map { record in
                    BookmarkedVariantExport.Row(
                        name: record.variantID, type: record.variantType, chromosome: record.chromosome,
                        start: record.position, ref: record.ref, alt: record.alt, quality: record.quality,
                        filter: record.filter
                    )
                }
            }
            guard !rows.isEmpty else {
                throw ViewerExportRefusal(
                    "No variant is bookmarked in \(databaseURLs.map(\.path).joined(separator: ", ")). "
                        + "Bookmark a variant with its star first."
                )
            }
            let content = BookmarkedVariantExport.tsv(rows: rows)
            var seen = Set<String>()
            let sourceURLs = databaseURLs.filter { seen.insert($0.path).inserted }
            var explicitOptions: [String: ParameterValue] = [
                "outputPath": .file(outputURL),
                "variantDatabasePaths": .array(databaseURLs.map { .file($0) }),
            ]
            if invocation.force {
                explicitOptions["force"] = .boolean(true)
            }
            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: BookmarkedVariantExport.workflowName,
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions,
                defaults: ["outputFormat": .string("tsv")],
                resolved: ["variantCount": .integer(rows.count)],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = rows.count == 1 ? "bookmarked variant" : "bookmarked variants"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported \(rows.count) \(noun) to \(outputURL.lastPathComponent)"
            )
        }
    }

    /// Writes the sample metadata template of a bundle's variant samples as TSV or CSV, with its record beside it.
    ///
    /// The leaf reads every variant database the bundle's manifest lists, in the order the drawer opens them, and
    /// writes one row for each sample and source file with an empty cell for each `--metadata-column`, under the
    /// `sample_name` and `source_file` headers `variants import-sample-metadata` reads back (BIO 5). It names the
    /// bundle's manifest, which lists the tracks, and those databases as inputs (BIO 6). The drawer's Download
    /// Template runs this leaf behind its Operations row.
    struct ExportSampleTemplateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sample-template",
            abstract: "Write a sample metadata template of a bundle's variant samples as TSV or CSV with provenance"
        )

        @Argument(help: "The reference bundle whose variant tracks hold the samples")
        var bundlePath: String

        /// The template writes an empty cell for each column, so this option does not share the group whose help says
        /// the values come from the result's metadata (`ViewerExportOptions.MetadataColumns`).
        @Option(
            name: .customLong(ViewerExportOption.metadataColumn.rawValue),
            parsing: .singleValue,
            help: "A sample metadata column to add to the template, by name. Repeat for more. Its cells are empty"
        )
        var metadataColumns: [String] = []

        @OptionGroup var format: ViewerExportOptions.ExportFormat<ViewerExportDelimitedFormat>
        @OptionGroup var output: ViewerExportOptions.Output
        @OptionGroup var globalOptions: GlobalOptions

        /// The invocation this parse stands for, which the record's argv comes from.
        func invocation() throws -> ViewerExportInvocation {
            var state = ViewerTableExportState()
            state.metadataColumns = metadataColumns
            return VariantSampleTemplateExport.invocation(
                bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
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
                startMessage: "Exporting the sample metadata template."
            ) { _ in
                try command.export()
            }
        }

        /// The export, which refuses before it writes and writes payload and record in one transaction.
        func export() throws -> ViewerExportLeafOutcome {
            let runClock = ProvenanceRunClock()
            let invocation = try invocation()
            let bundleURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
            let outputURL = URL(fileURLWithPath: invocation.output)
            let tracks: [VariantEditTargets.Track]
            do {
                tracks = try VariantEditTargets.tracks(inBundleAt: bundleURL)
            } catch {
                throw ViewerExportRefusal("No bundle manifest can be read at \(bundleURL.path). Pass the bundle the app opens. \(error)")
            }
            var seen = Set<String>()
            let databaseURLs = tracks.map(\.databaseURL).filter { seen.insert($0.standardizedFileURL.path).inserted }
            let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
            let inputURLs = [manifestURL] + databaseURLs
            try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: inputURLs, force: invocation.force)

            var databases: [VariantDatabase] = []
            for databaseURL in tracks.map(\.databaseURL) {
                do {
                    databases.append(try VariantDatabase(url: databaseURL))
                } catch {
                    throw ViewerExportRefusal("The variant database at \(databaseURL.path) cannot be read. \(error)")
                }
            }
            let rows = VariantSampleTemplateExport.sampleRows(databases: databases)
            guard !rows.isEmpty else {
                throw ViewerExportRefusal("No variant track of \(bundleURL.path) holds a sample. Import a VCF with samples first.")
            }
            let columns = invocation.state.metadataColumns
            let content = VariantSampleTemplateExport.template(
                rows: rows, metadataColumns: columns, separator: format.format.separator
            )
            var explicitOptions: [String: ParameterValue] = [
                "outputPath": .file(outputURL),
                "outputFormat": .string(format.format.rawValue),
            ]
            if !columns.isEmpty {
                explicitOptions["metadataColumns"] = .array(columns.map(ParameterValue.string))
            }
            if invocation.force {
                explicitOptions["force"] = .boolean(true)
            }
            try Task.checkCancellation()
            try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                workflowName: VariantSampleTemplateExport.workflowName,
                sourceURLs: inputURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: invocation.canonicalArgv(),
                explicitOptions: explicitOptions,
                resolved: [
                    "sampleCount": .integer(rows.count),
                    "metadataColumns": .array(columns.map(ParameterValue.string)),
                ],
                runClock: runClock
            )) { stagedURL in
                try content.write(to: stagedURL, atomically: true, encoding: .utf8)
                try ViewerExportLeaf.checkpointAfterStaging()
            }
            let noun = rows.count == 1 ? "sample" : "samples"
            return ViewerExportLeafOutcome(
                outputURL: outputURL,
                message: "Exported a template of \(rows.count) \(noun) to \(outputURL.lastPathComponent)"
            )
        }
    }
}
