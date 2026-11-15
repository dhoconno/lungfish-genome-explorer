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

    /// Writes the record through the durable write path. The same record again changes nothing, and a record that names
    /// other digests for the same set and key is refused in words, since one key names one index.
    @discardableResult
    package func write(_ record: STARIndexRecord) throws -> URL {
        let target = try url(setID: record.setID, key: record.key.folderName)
        if let existing = try find(setID: record.setID, key: record.key.folderName) {
            guard existing == record else {
                throw STARIndexError("The index record of \(record.key.folderName) for the set \(record.setID) already names other "
                    + "digests, so it was not replaced. Build the index under another key, or remove the old record yourself.")
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
}
