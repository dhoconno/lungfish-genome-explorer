// AnnotationTableExportStreamCapture.swift - Runs bundle export-annotation-table in process on a small bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

/// The runs of `bundle export-annotation-table` (Phase 2.12 lane 12.39) whose `--format json` standard output is
/// checked in under `Tests/Fixtures/cli-events/commands/bundle-export-annotation-table`. The command needs no tool.
/// `CLIEventTranscriptCoverageTests` runs them through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`. The bundle is `AnnotationGFF3ExportStreamCapture`'s, one gene in one database.
enum AnnotationTableExportStreamCapture {
    /// The columns the drawer's annotations tab shows for the fixture's gene, with an attribute column.
    static let annotationColumns = [
        ScientificTableColumn(id: "NameColumn", title: "Name"),
        ScientificTableColumn(id: "TypeColumn", title: "Type"),
        ScientificTableColumn(id: "ChromosomeColumn", title: "Chromosome"),
        ScientificTableColumn(id: "StartColumn", title: "Start"),
        ScientificTableColumn(id: "EndColumn", title: "End"),
        ScientificTableColumn(id: "StrandColumn", title: "Strand"),
        ScientificTableColumn(id: "TrackNameColumn", title: "Track"),
        ScientificTableColumn(id: "attr_tag", title: "tag"),
    ]

    /// The annotations tab's selection of the given rows, as the drawer writes it.
    static func annotationSelection(identities: [String] = ["genes:1"]) -> ViewerExportSelection {
        ViewerExportSelection(
            identities: identities,
            annotationTable: AnnotationTableExportSelection(
                scope: AnnotationTableExportScope.allMatching.rawValue,
                columns: annotationColumns,
                query: ["text": "", "sort": "database-default:ascending"]
            )
        )
    }

    static func cases() -> [ImportStreamCapture.Case] {
        func run(_ scratch: ImportStreamCapture.Scratch, bundle: URL) async throws -> ImportStreamCapture.Output {
            let selectionURL = scratch.root.appendingPathComponent("selection.json")
            try annotationSelection().encoded().write(to: selectionURL)
            let command = try BundleExportAnnotationTableSubcommand.parse([
                bundle.path, "--tab", "annotations", "--output-format", "tsv", "--selection", selectionURL.path,
                "-o", scratch.root.appendingPathComponent("fixture.tsv").path, "--format", "json",
            ])
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }
        return [
            ImportStreamCapture.Case(leaf: "bundle export-annotation-table", name: "complete") { scratch in
                try await run(scratch, bundle: try AnnotationGFF3ExportStreamCapture.makeBundle(in: scratch.root))
            },
            // A folder with no manifest is refused before anything is written, with exit 3.
            ImportStreamCapture.Case(leaf: "bundle export-annotation-table", name: "failed") { scratch in
                try await run(scratch, bundle: scratch.root.appendingPathComponent("missing.lungfishref", isDirectory: true))
            },
        ]
    }
}
