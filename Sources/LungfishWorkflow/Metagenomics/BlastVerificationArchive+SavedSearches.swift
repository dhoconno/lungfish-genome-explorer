// BlastVerificationArchive+SavedSearches.swift - The newest saved `blast submit` record a viewer asks for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

/// What a row has to show, as its project's `blast-verifications` folder holds it.
package enum BlastRowSearch: Sendable {
    /// The newest thing on the row is a saved result.
    case saved(record: BlastSubmissionRecord, url: URL)
    /// The newest thing on the row is a search with no record to show, waiting or ended with no result.
    case live(BlastLiveSearch)
    /// The row's only search was sent from a source result since replaced, so its result stays off the row.
    case sourceReplaced(folder: URL)
}

extension BlastVerificationArchive {
    /// The newest search of a row, with no record or with one (ARCH-BLAST-RESILIENCE section 6, BLAST-WAITING-NOT-ON-ROW).
    /// A newer search that waits outranks an older result, since it is the last thing the person asked for. A result whose
    /// source was replaced after it went out never lands on the row (BIO reads this line). It reads every folder, so it
    /// never runs on the main actor. A cancelled task stops reading and gets nothing.
    package static func newestSearch(
        in directory: URL,
        matching matches: (BlastSubmissionRecord.Lineage, URL) -> Bool
    ) -> BlastRowSearch? {
        let root = directoryURL(for: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var newest: (date: Date, search: BlastRowSearch)?
        var replaced: URL?
        func offer(_ date: Date, _ search: BlastRowSearch) {
            if let current = newest, current.date >= date { return }
            newest = (date, search)
        }
        for name in names where !name.hasPrefix("._") {
            if Task.isCancelled { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let live = BlastLiveSearch.read(folder: folder)
            if let live, live.file.state != .done, let lineage = live.file.lineage {
                let searchURL = folder.appendingPathComponent(BlastSearchFile.fileName)
                guard matches(lineage, searchURL) else { continue }
                // A search still at NCBI has not come back, so it says nothing on the new rows, and its own row goes on.
                guard sourceHolds(live.file, lineage: lineage, at: searchURL) else { continue }
                offer(live.file.createdAt, .live(live))
                continue
            }
            let url = folder.appendingPathComponent(BlastSubmissionRecord.recordFileName)
            guard let record = try? BlastSubmissionRecord.load(url), matches(record.lineage, url) else { continue }
            if let file = live?.file, !sourceHolds(file, lineage: record.lineage, at: url) {
                replaced = folder
                continue
            }
            offer(record.result.completedAt ?? record.savedAt, .saved(record: record, url: url))
        }
        return newest?.search ?? replaced.map { .sourceReplaced(folder: $0) }
    }

    /// What tells one run of a source result from another, which `blast submit` keeps in the search file. A root record's ID
    /// names its run and stays through a later write to that record, such as a database build's. A record with no ID gives
    /// its digest. A folder from before root records gives the digest of the document its viewer loads, so its guard is not
    /// empty. Nil for a source with none of these: a plain FASTA, whose route looks up no row, and a folder no viewer opens.
    package static func sourceStamp(ofResult resultURL: URL) -> String? {
        let record = resultURL.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        guard let data = try? Data(contentsOf: record) else { return documentStamp(ofResult: resultURL) }
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let run = fields?["id"] as? String { return "run:" + run }
        return "record:" + digest(of: data)
    }

    /// The document each route's viewer loads: Kraken2, EsViritu, TaxTriage, and NVD and NAO-MGS.
    private static let sourceDocumentNames = ["classification-result.json", "esviritu-result.json", "taxtriage-result.json", "manifest.json"]
    private static let documentStampPrefix = "document:"

    private static func documentStamp(ofResult resultURL: URL) -> String? {
        for name in sourceDocumentNames {
            if let data = try? Data(contentsOf: resultURL.appendingPathComponent(name)) {
                return documentStampPrefix + digest(of: data)
            }
        }
        return nil
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a search's source is still the one it was sent from. A search with no stamp cannot tell, so it holds. A search
    /// folder inside its own source travels with it, and a copy of the source writes a new root record there, so it holds.
    /// A root record written later into an older folder is no new run, so a document's stamp compares with the document.
    private static func sourceHolds(_ file: BlastSearchFile, lineage: BlastSubmissionRecord.Lineage, at url: URL) -> Bool {
        guard let sent = file.sourceStamp, let source = lineage.sourceResultURL(recordAt: url) else { return true }
        let inside = url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(source.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        if inside { return true }
        let now = sent.hasPrefix(documentStampPrefix) ? documentStamp(ofResult: source) : sourceStamp(ofResult: source)
        guard let now else { return sourceStamp(ofResult: source) == nil }
        return sent == now
    }

    /// The newest readable `blast submit` record under `<directory>/blast-verifications/` that `matches` accepts, with
    /// the file it was read from, which the BLAST pane's table export reads. The search that completed last wins, as the
    /// archive orders its own files. A folder with no readable record, which a timed-out run leaves, is skipped.
    ///
    /// It reads every record, so it never runs on the main actor. A cancelled task stops reading and gets nothing.
    public static func newestSubmission(
        in directory: URL,
        matching matches: (BlastSubmissionRecord, URL) -> Bool
    ) -> (record: BlastSubmissionRecord, url: URL)? {
        let folder = directoryURL(for: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var newest: (record: BlastSubmissionRecord, url: URL)?
        for name in names {
            if Task.isCancelled { return nil }
            let url = folder.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(BlastSubmissionRecord.recordFileName)
            guard let record = try? BlastSubmissionRecord.load(url), matches(record, url) else { continue }
            if let current = newest, completion(of: current.record) >= completion(of: record) { continue }
            newest = (record, url)
        }
        return newest
    }

    /// The project that holds `resultURL`, whose `blast-verifications` folder takes the result's searches.
    public static func savedSearchProject(ofResult resultURL: URL) -> URL? {
        ProjectTempDirectory.findProjectRoot(resultURL)
    }

    private static func completion(of record: BlastSubmissionRecord) -> Date {
        record.result.completedAt ?? record.savedAt
    }
}
