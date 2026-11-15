// STARIndexRecordStore.swift - The one owner of `<storage root>/rnaseq-index-records/` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Keeps the records of STAR indexes that live on a Linux machine, one place for them all:
/// `<storage root>/rnaseq-index-records/<set id>/<key>/index-record.json`, which a later plan writer finds by set id and
/// key. The folder holds no index file, only the record that names where each file sits and its digests. No cleanup of
/// LGE reaches it, and nothing here removes a record (`docs/formats/reference-set.md`, Cleanup).
package struct STARIndexRecordStore: Sendable {
    package static let folderName = "rnaseq-index-records"
    package var storageRoot: URL

    package init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    /// The record's file. The set id comes from a manifest and the key from a run record, so each must be one plain folder
    /// name, and any other is refused before a folder is read or made, inside `rnaseq-index-records/` or outside it.
    package func url(setID: String, key: String) throws -> URL {
        let set = try Self.folder(setID, "set id", "the set's reference-set.json")
        let index = try Self.folder(key, "index key", "the STAR version in the run record")
        return storageRoot.appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(set, isDirectory: true).appendingPathComponent(index, isDirectory: true)
            .appendingPathComponent(STARIndexRecord.fileName)
    }

    private static func folder(_ name: String, _ what: String, _ source: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw STARIndexError("The \(what) \"\(name)\" is not one plain folder name, so no index record was read or written "
                + "by it. LGE never writes such a name, so check \(source).")
        }
        return name
    }

    package func find(setID: String, key: String) throws -> STARIndexRecord? {
        let url = try url(setID: setID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(STARIndexRecord.self, from: Data(contentsOf: url))
    }

    /// Writes the record through the durable write path. The same record again changes nothing, and another record for the
    /// same set and key is refused in words that name the record's file and what differs, since one key names one index.
    @discardableResult
    package func write(_ record: STARIndexRecord) throws -> URL {
        let target = try url(setID: record.setID, key: record.key.folderName)
        if let existing = try find(setID: record.setID, key: record.key.folderName) {
            guard existing == record else {
                throw STARIndexError("The index record \(target.path) already names " + Self.differences(existing, record)
                    + ", so it was not replaced. If this run is the one to keep, remove that file and adopt again.")
            }
            return target
        }
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DurableReplace.replace(try encoder.encode(record), named: STARIndexRecord.fileName, in: folder)
        return target
    }

    /// What a new record of the same set and key changes against the one on disk, such as `the same digests with its files
    /// under <old folder>, where this adopt names <new folder>` when the index was adopted again under another batch.
    static func differences(_ old: STARIndexRecord, _ new: STARIndexRecord) -> String {
        let digests = { (record: STARIndexRecord) in Set(record.files.map { "\($0.path) \($0.bytes) \($0.sha256)" }) }
        let changed = max(digests(new).subtracting(digests(old)).count, digests(old).subtracting(digests(new)).count)
        let folders = { (record: STARIndexRecord) in
            Set(record.files.map { ($0.stagingPath as NSString).deletingLastPathComponent }).sorted().joined(separator: " and ")
        }
        let (was, now) = (old.key, new.key)
        let named: [String?] = [
            folders(old) == folders(new) ? nil : "its files under \(folders(old)), where this adopt names \(folders(new))",
            old.tool == new.tool && was.star == now.star ? nil : "the STAR build \(old.tool.build), where this run names \(new.tool.build)",
            was.sjdbOverhang == now.sjdbOverhang ? nil : "--sjdbOverhang \(was.sjdbOverhang), where this run names \(now.sjdbOverhang)",
            was.genomeFastaFiles == now.genomeFastaFiles ? nil : "other FASTA files",
            was.countingGTFSHA256 == now.countingGTFSHA256 ? nil : "another SHA-256 of derived/genes.gtf",
            was.referenceSetSHA256 == now.referenceSetSHA256 ? nil : "another SHA-256 of reference-set.json",
        ]
        let others = named.compactMap { $0 }
        guard changed > 0 else { return "the same digests with " + (others.isEmpty ? ["other values"] : others).joined(separator: " and ") }
        return (["other digests for \(changed) of \(new.files.count) files"] + others).joined(separator: " and ")
    }
}
