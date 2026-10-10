// AppProvenanceExportSourceResolver.swift - Which file or bundle File > Export > Provenance exports from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The record File > Export > Provenance writes out, with the file or bundle it describes.
struct AppProvenanceExportSource: Equatable {
    let selectedURL: URL
    let sourceSidecarURL: URL
    let envelope: ProvenanceEnvelope
}

/// What File > Export > Provenance found for the current selection.
enum AppProvenanceExportResolution: Equatable {
    /// A record exists for the file or bundle the export describes.
    case resolved(AppProvenanceExportSource)
    /// A file or bundle is selected and has no record. The caller says so and exports nothing.
    case unresolvedSelection(URL)
    /// Neither the viewer nor the sidebar names a source.
    case noCurrentSource
}

/// Chooses the file or bundle File > Export > Provenance describes, and finds its record.
///
/// The choice is a pure function of the viewer's candidates, the sidebar selection and a lookup,
/// so a test drives it without a window or a sidecar on disk.
enum AppProvenanceExportSourceResolver {
    /// Finds the record that applies to a file or bundle. The app passes
    /// `ProvenanceRecorder.findProvenanceEnvelope(for:)`.
    typealias RecordLookup = (URL) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)?

    /// Resolves the export source.
    ///
    /// A chosen file or bundle without a record is `unresolvedSelection`, and no other record
    /// stands in for it. `noCurrentSource` means nothing is selected and the viewer names nothing.
    static func resolve(
        viewerCandidates: [URL?],
        sidebarSelection: URL?,
        findRecord: RecordLookup
    ) -> AppProvenanceExportResolution {
        guard let target = exportTarget(viewerCandidates: viewerCandidates, sidebarSelection: sidebarSelection) else {
            return .noCurrentSource
        }
        guard let found = findRecord(target) else {
            return .unresolvedSelection(target)
        }
        return .resolved(
            AppProvenanceExportSource(
                selectedURL: target,
                sourceSidecarURL: found.sidecarURL,
                envelope: found.envelope
            )
        )
    }

    /// The file or bundle the export describes, standardized, or nil when there is none.
    ///
    /// The sidebar selection decides, because it is what the user picked. The Provenance tab can
    /// follow the file the viewer loaded instead, so the tab and the export can name different
    /// sources until both read one source. A viewer candidate takes the selection's place only
    /// when it is the selection or a bundle that contains it, since that bundle's record then
    /// describes the selected file. Candidates are tried in the order given, and containment
    /// compares physical paths so a symlinked spelling of the same bundle counts. A Quick Look
    /// style preview never resets the viewer's current document, so that candidate can name a file
    /// that is no longer shown. It is neither the selection nor a bundle around it, so it never
    /// decides while something else is selected. With nothing selected the first viewer candidate
    /// is used.
    static func exportTarget(viewerCandidates: [URL?], sidebarSelection: URL?) -> URL? {
        let candidates = viewerCandidates.compactMap { $0?.standardizedFileURL }
        guard let selection = sidebarSelection?.standardizedFileURL else {
            return candidates.first
        }
        return candidates.first { CanonicalFilePath.isPath(selection, within: $0) } ?? selection
    }
}
