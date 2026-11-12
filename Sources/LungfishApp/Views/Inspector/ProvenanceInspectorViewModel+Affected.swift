// ProvenanceInspectorViewModel+Affected.swift - The sentence of an affected result, under its record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension Notification.Name {
    /// Posted after each lookup of the Provenance model. The model is the `object`, and `userInfo` holds the
    /// matched ``AffectedResultRow``s under ``ProvenanceInspectorViewModel/affectedResultsRowsKey``, none when the
    /// record names an unaffected build. The viewer's strip listens (`ViewerViewController+AffectedResultsStrip`).
    static let affectedResultsDidChange = Notification.Name("LungfishAffectedResultsDidChange")
}

extension ProvenanceInspectorViewModel {
    /// The title of the Warnings row that carries the sentence.
    static let affectedResultsWarningTitle = "Affected result"
    static let affectedResultsRowsKey = "affectedResultRows"

    /// The kind of result `item` is, as the rows of ``AffectedResults`` name it, or nil for an item no row speaks about.
    nonisolated static func affectedResultKind(for item: ProvenanceInspectableItem) -> AffectedResultKind? {
        switch item.sidebarType {
        case .taxTriageResult: return .taxTriage
        case .esvirituResult: return .esViritu
        case .classificationResult: return .kraken2
        case .naoMgsResult: return .naoMgs
        case .nvdResult: return .nvd
        case .analysisResult:
            // A result in the Analyses folder names its tool in its metadata.
            guard let url = item.url, let tool = AnalysesFolder.readAnalysisMetadata(from: url)?.tool else { return nil }
            return affectedResultKind(forTool: tool)
        default: return nil
        }
    }

    nonisolated static func affectedResultKind(forTool tool: String) -> AffectedResultKind? {
        let name = tool.lowercased()
        if name.contains("taxtriage") { return .taxTriage }
        if name.contains("esviritu") { return .esViritu }
        if name.contains("kraken") { return .kraken2 }
        if name.contains("naomgs") || name.contains("nao-mgs") { return .naoMgs }
        if name.contains("nvd") { return .nvd }
        if ["spades", "megahit", "skesa", "flye", "hifiasm"].contains(where: name.contains) { return .assembly }
        return nil
    }

    /// Puts the sentence and what to do of each affected row under the record, in the Warnings, and tells the
    /// viewer. It runs after the lookup has built the record's rows, and it reads the record that lookup found
    /// without writing into the project. A record that names an unaffected build, a build with no number or no
    /// record at all adds nothing, and the viewer's strip goes.
    func applyAffectedResults(item: ProvenanceInspectableItem) {
        let rows: [AffectedResultRow]
        if let envelope = resolvedEnvelope, let kind = Self.affectedResultKind(for: item) {
            rows = AffectedResults.rows(for: envelope, kind: kind)
        } else {
            rows = []
        }
        let shownBefore = warnings.count
        warnings.removeAll { $0.title == Self.affectedResultsWarningTitle }
        let removedRows = warnings.count != shownBefore
        warnings.append(contentsOf: rows.map {
            ProvenanceWarningRow(title: Self.affectedResultsWarningTitle, message: $0.words)
        })
        // Copy copies every displayed row, so the copy text the lookup built follows the Warnings.
        if removedRows || !rows.isEmpty, resolvedEnvelope != nil {
            copyableText = buildCopyableText()
        }
        NotificationCenter.default.post(
            name: .affectedResultsDidChange, object: self,
            userInfo: [Self.affectedResultsRowsKey: rows]
        )
    }
}
