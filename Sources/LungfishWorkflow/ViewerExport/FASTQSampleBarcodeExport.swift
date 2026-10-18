// FASTQSampleBarcodeExport.swift - The FASTQ metadata drawer's sample sheet export that the drawer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The tabs of the FASTQ metadata drawer that export a sample sheet (`--tab`).
public enum FASTQSampleBarcodeTab: String, CaseIterable, Sendable {
    case samples
    case demux
}

/// The FASTQ metadata export (Phase 2.12 lane 12.34, ARCH ruling 1.1 row A13 and 1.3).
///
/// The sheet is the drawer's table, and its rows may hold edits that are not saved, so the leaf cannot rebuild them
/// from the bundle. The drawer writes them to a selection file before the row begins, and the leaf writes the sheet
/// from that file with ``csv(assignments:tab:asymmetric:)``. The selection holds identities and values, never the
/// rendered sheet: each row's identity is its position in the table (sample ids can repeat while the user edits), its
/// edited values are the row's fields, and the demux step's symmetry sits in the state's `mode`.
public enum FASTQSampleBarcodeExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A13).
    public static let commandPath = ["fastq", "export", "sample-barcodes"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish fastq export sample-barcodes"
    /// The `mode` of a selection whose demux step reads barcode ids only.
    public static let asymmetricMode = "asymmetric"
    /// The `mode` of a selection whose demux step has sequences on both ends.
    public static let symmetricMode = "symmetric"
    /// The prefix of a row field that holds a custom metadata column.
    public static let metadataFieldPrefix = "metadata."

    /// The leaf's invocation for a drawer state, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        bundleURL: URL,
        tab: FASTQSampleBarcodeTab,
        selectionURL: URL,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            tab: tab.rawValue,
            selection: selectionURL.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The selection that carries the drawer's rows as they stand at the click.
    public static func selection(
        assignments: [FASTQSampleBarcodeAssignment],
        asymmetric: Bool
    ) -> ViewerExportSelection {
        var identities: [String] = []
        var rows: [String: [String: String]] = [:]
        for (index, assignment) in assignments.enumerated() {
            var fields = ["sampleID": assignment.sampleID]
            fields["sampleName"] = assignment.sampleName
            fields["forwardBarcodeID"] = assignment.forwardBarcodeID
            fields["forwardSequence"] = assignment.forwardSequence
            fields["reverseBarcodeID"] = assignment.reverseBarcodeID
            fields["reverseSequence"] = assignment.reverseSequence
            for (key, value) in assignment.metadata {
                fields[metadataFieldPrefix + key] = value
            }
            identities.append(String(index))
            rows[String(index)] = fields
        }
        return ViewerExportSelection(
            identities: identities,
            state: ViewerTableExportState(mode: asymmetric ? asymmetricMode : symmetricMode),
            editedValues: rows
        )
    }

    /// The rows a selection holds in its order, or nil when an identity has no values or a row has no sample id.
    public static func assignments(in selection: ViewerExportSelection) -> [FASTQSampleBarcodeAssignment]? {
        var assignments: [FASTQSampleBarcodeAssignment] = []
        for identity in selection.identities {
            guard let fields = selection.editedValues[identity], let sampleID = fields["sampleID"] else { return nil }
            var metadata: [String: String] = [:]
            for (key, value) in fields where key.hasPrefix(metadataFieldPrefix) {
                metadata[String(key.dropFirst(metadataFieldPrefix.count))] = value
            }
            assignments.append(FASTQSampleBarcodeAssignment(
                sampleID: sampleID,
                sampleName: fields["sampleName"],
                forwardBarcodeID: fields["forwardBarcodeID"],
                forwardSequence: fields["forwardSequence"],
                reverseBarcodeID: fields["reverseBarcodeID"],
                reverseSequence: fields["reverseSequence"],
                metadata: metadata
            ))
        }
        return assignments
    }

    /// Whether the selection's demux step reads barcode ids only.
    public static func isAsymmetric(_ selection: ViewerExportSelection) -> Bool {
        selection.state.mode == asymmetricMode
    }

    /// The sheet the drawer writes. Only the Demux tab of an asymmetric step writes barcode ids alone.
    public static func csv(
        assignments: [FASTQSampleBarcodeAssignment],
        tab: FASTQSampleBarcodeTab,
        asymmetric: Bool
    ) -> String {
        if tab == .demux && asymmetric {
            return FASTQSampleBarcodeCSV.exportAsymmetricCSV(assignments)
        }
        return FASTQSampleBarcodeCSV.exportCSV(assignments)
    }
}
