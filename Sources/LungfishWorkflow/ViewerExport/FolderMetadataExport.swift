// FolderMetadataExport.swift - The folder and project metadata CSV export that the app and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The folder and project metadata CSV export (Phase 2.12 lane 12.38, ARCH ruling 1.1 row B12 and 1.3).
///
/// Both sheets of the app export rows that live only in the view. The folder sheet exports its table with the edits
/// the user has not saved, and the project export writes the samples the user ticked. The leaf cannot rebuild either
/// from the folder's files, so the app writes the rows to a selection file before the row begins, and
/// `lungfish-cli metadata export --selection` writes the CSV from that file with ``csv(samples:)``. The selection
/// holds each sample as the values it stands for, never the rendered CSV. A row's identity is its position, since two
/// samples can share a name while the user edits. Without `--selection` the leaf reads the folder's own metadata
/// files, which ``sourceFiles(in:)`` lists for its record.
public enum FolderMetadataExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row B12).
    public static let commandPath = ["metadata", "export"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish metadata export"
    /// The selection row field that holds one sample, encoded as JSON with sorted keys.
    public static let sampleField = "sample"
    /// The selection row field that names the sample for a reader of the file. The leaf ignores it.
    public static let nameField = "sampleName"

    /// The leaf's invocation for an export, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        folderURL: URL,
        selectionURL: URL?,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = false
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: folderURL.standardizedFileURL.path,
            selection: selectionURL?.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The selection that carries the samples as the sheet holds them at the click, in the order it exports them.
    public static func selection(samples: [FASTQSampleMetadata]) throws -> ViewerExportSelection {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var identities: [String] = []
        var rows: [String: [String: String]] = [:]
        for (index, sample) in samples.enumerated() {
            let identity = String(index)
            identities.append(identity)
            rows[identity] = [
                nameField: sample.sampleName,
                sampleField: String(decoding: try encoder.encode(sample), as: UTF8.self),
            ]
        }
        return ViewerExportSelection(identities: identities, editedValues: rows)
    }

    /// The samples a selection holds in its order, or nil when a row holds no sample the type can read.
    public static func samples(in selection: ViewerExportSelection) -> [FASTQSampleMetadata]? {
        let decoder = JSONDecoder()
        var samples: [FASTQSampleMetadata] = []
        for identity in selection.identities {
            guard let json = selection.editedValues[identity]?[sampleField],
                  let sample = try? decoder.decode(FASTQSampleMetadata.self, from: Data(json.utf8)) else {
                return nil
            }
            samples.append(sample)
        }
        return samples
    }

    /// The CSV both sheets write, which is the serializer they called before the leaf.
    public static func csv(samples: [FASTQSampleMetadata]) -> String {
        FASTQSampleMetadata.serializeMultiSampleCSV(samples)
    }

    /// The files `FASTQFolderMetadata.loadResolved(from:)` reads in `folderURL` that exist, which are the folder's
    /// `samples.csv` and the `metadata.csv` of each `.lungfishfastq` bundle. The record names them as the inputs.
    public static func sourceFiles(in folderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        let folderFile = folderURL.appendingPathComponent(FASTQFolderMetadata.filename)
        if fileManager.fileExists(atPath: folderFile.path) {
            urls.append(folderFile)
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []
        for name in names.filter({ $0.hasSuffix(".lungfishfastq") }).sorted() {
            let bundleFile = folderURL
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(FASTQBundleCSVMetadata.filename)
            if fileManager.fileExists(atPath: bundleFile.path) {
                urls.append(bundleFile)
            }
        }
        return urls
    }
}
