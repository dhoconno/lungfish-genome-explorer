// DocumentSection+RNASeq.swift - The Bundle tab of an open RNA-seq result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// What the Bundle tab shows for an open RNA-seq result: the facts its manifest writes, then for a cell map the fact
/// lines of what the view draws (5.5 V5). Each part has its own setter, so for the same result neither replaces the
/// other, and the cell map part shows on first open whichever of the view's refresh and the surface's loaded hook
/// comes first.
struct RNASeqResultDocumentState: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
    }

    let bundleURL: URL
    /// The result's facts (`RNASeqResultFacts.rows`), nil until the surface's loaded hook gives them.
    var header: [Row]?
    /// The cell map's fact lines for the embedding and colouring shown. Empty for a bulk or single-cell result, and
    /// after the cell map closes or a reread fails.
    var cellMap: [Row] = []

    /// One row for each label and value, its id `prefix` and the label in lower case with spaces as hyphens.
    static func rows(_ pairs: [(label: String, value: String)], prefix: String) -> [Row] {
        pairs.map { pair in
            Row(id: "\(prefix)-\(pair.label.lowercased().replacingOccurrences(of: " ", with: "-"))",
                label: pair.label, value: pair.value)
        }
    }
}

extension DocumentSectionViewModel {
    /// Sets the facts of the RNA-seq result at `bundleURL`. For the result already shown only the facts change.
    /// Another result clears every other document mode first.
    func updateRNASeqResultHeader(_ rows: [RNASeqResultDocumentState.Row], bundleURL: URL) {
        let url = bundleURL.standardizedFileURL
        if rnaseqResultDocument?.bundleURL == url {
            rnaseqResultDocument?.header = rows
            return
        }
        clearForDocumentMode()
        rnaseqResultDocument = RNASeqResultDocumentState(bundleURL: url, header: rows)
    }

    /// Sets the cell map's fact lines of the result at `bundleURL`. For the result already shown only the lines
    /// change, so an empty list empties them. Lines of another result clear every other document mode first, and an
    /// empty list of another result changes nothing.
    func updateRNASeqResultCellMap(_ rows: [RNASeqResultDocumentState.Row], bundleURL: URL) {
        let url = bundleURL.standardizedFileURL
        if rnaseqResultDocument?.bundleURL == url {
            rnaseqResultDocument?.cellMap = rows
            return
        }
        guard !rows.isEmpty else { return }
        clearForDocumentMode()
        rnaseqResultDocument = RNASeqResultDocumentState(bundleURL: url, header: nil, cellMap: rows)
    }
}

/// The rows of an open RNA-seq result: its facts, then the cell map's lines. Each row is one accessibility element
/// with the row's label as its label and the fact as its value, read in the order drawn.
struct RNASeqResultDocumentSection: View {
    let state: RNASeqResultDocumentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.header ?? []) { row($0) }
            if !state.cellMap.isEmpty {
                Divider()
                ForEach(state.cellMap) { row($0) }
            }
        }
    }

    private func row(_ row: RNASeqResultDocumentState.Row) -> some View {
        // The value's text is the row's one element, so VoiceOver reads the label then the fact, and the label's own
        // text is hidden from it.
        HStack(alignment: .top, spacing: 8) {
            Text(row.label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
                .accessibilityHidden(true)
            Text(row.value)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.value)
                .accessibilityIdentifier(row.id)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
