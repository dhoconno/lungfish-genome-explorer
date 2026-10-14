// FetchNCBIBundleRecord.swift - The provenance record of a bundle that lungfish-cli fetch ncbi --bundle built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The record of one `fetch ncbi --bundle` bundle (Phase 2.10 lane A45, BIO B-3 and B-5).
///
/// `GenBankDownloadBundleBuilder` writes the record while it builds, and names every file of the
/// bundle at the place it built it. The CLI builds in a staging folder and moves the bundle into
/// the output folder, so the record is rewritten once the bundle is in its final place: the same
/// run, the same steps and digests, with the staging path replaced by the final one and the layout
/// the writer gives a bundle. The record names the accession as requested and as NCBI resolved it,
/// with its version, each fetched file under its source URL with the digest it arrived with, and
/// the time of the fetch. The run's argument vector is the CLI's own, so the record replays the
/// command that made it.
enum FetchNCBIBundleRecord {
    /// Rewrites the record of `bundle`, which was built at `staged` and now sits at `bundle`. It
    /// does nothing when the bundle holds no record.
    static func rebase(bundle: URL, from staged: URL) throws {
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: bundle) else { return }
        var text = String(decoding: try ProvenanceJSON.encoder.encode(envelope), as: UTF8.self)
        // The builder keeps the spelling of the path it was given, and a reader may resolve it, so
        // every spelling of the staged path goes, the longest first.
        let spellings = Set([staged.path, staged.resolvingSymlinksInPath().path, "/private" + staged.path])
            .sorted { $0.count > $1.count }
        for spelling in spellings where !spelling.isEmpty {
            text = text.replacingOccurrences(of: spelling, with: bundle.path)
        }
        let rebased = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(text.utf8))
        try FetchGenomeRun.removeBuilderRecord(of: bundle)
        try ProvenanceWriter(signingProvider: nil).write(rebased, to: bundle)
    }
}
