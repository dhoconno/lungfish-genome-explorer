// VariantSampleTemplateExport.swift - The sample metadata template that the variant drawer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The sample metadata template export (Phase 2.12 lane 12.39, ARCH ruling X-1 row B11).
///
/// The variant drawer's Download Template and `variants export sample-template` list the samples of a bundle's
/// variant databases with these functions, which keep the rows the drawer wrote before the leaf, so a template the
/// user fills in imports back through `variants import-sample-metadata` (BIO 5).
public enum VariantSampleTemplateExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, row B11).
    public static let commandPath = ["variants", "export", "sample-template"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish variants export sample-template"

    /// The leaf's invocation for a bundle and the drawer's metadata columns, with absolute standardized paths.
    public static func invocation(
        bundleURL: URL,
        metadataColumns: [String],
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        var state = ViewerTableExportState()
        state.metadataColumns = metadataColumns
        return ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            state: state,
            outputFormat: format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The format the drawer writes for a file the save panel named, CSV for a `.csv` name and TSV otherwise.
    public static func format(forOutput url: URL) -> ViewerExportDelimitedFormat {
        url.pathExtension.lowercased() == "csv" ? .csv : .tsv
    }

    /// One row for each sample and source file, database by database, each database's samples in its
    /// `sampleNames()` order. A sample whose name and source file match an earlier row's, ignoring case, is left out.
    public static func sampleRows(databases: [VariantDatabase]) -> [(name: String, sourceFile: String)] {
        var sampleRows: [(name: String, sourceFile: String)] = []
        var seenRows = Set<String>()
        for db in databases {
            let dbSourceFiles = db.allSourceFiles()
            for sampleName in db.sampleNames() {
                let sourceFile = dbSourceFiles[sampleName] ?? ""
                let normalizedKey = "\(sampleName.lowercased())|\(sourceFile.lowercased())"
                if seenRows.insert(normalizedKey).inserted {
                    sampleRows.append((name: sampleName, sourceFile: sourceFile))
                }
            }
        }
        return sampleRows
    }

    /// The template, a `sample_name` and `source_file` header, then the metadata columns, with each row's metadata
    /// cells empty. Values are written as they are, unquoted, as the drawer wrote them.
    public static func template(
        rows: [(name: String, sourceFile: String)],
        metadataColumns: [String],
        separator: String
    ) -> String {
        let header = (["sample_name", "source_file"] + metadataColumns).joined(separator: separator)
        let lines = rows.map { row in
            ([row.name, row.sourceFile] + Array(repeating: "", count: metadataColumns.count)).joined(separator: separator)
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }
}
