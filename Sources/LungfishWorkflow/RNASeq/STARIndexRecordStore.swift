// STARIndexRecordStore.swift - The one owner of `<storage root>/rnaseq-index-records/` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishPortable

/// Keeps the records of STAR indexes that live on a Linux machine, one place for them all:
/// `<storage root>/rnaseq-index-records/<set id>/<key>/index-record.json`, which a later plan writer finds by set id and
/// key. The folder holds no index file, only the record that names where each file sits and its digests, and since schema 2
/// the run record that built the index, kept as `run-record.json` beside it. No cleanup of LGE reaches it, and nothing here
/// removes a record (`docs/formats/reference-set.md`, Cleanup).
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

    /// The byte copy of the run record that sits beside the record, which a record of schema 2 names by SHA-256.
    package func runRecordURL(setID: String, key: String) throws -> URL {
        try url(setID: setID, key: key).deletingLastPathComponent().appendingPathComponent(STARIndexRecord.runRecordFileName)
    }

    private static func folder(_ name: String, _ what: String, _ source: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw STARIndexError("The \(what) \"\(name)\" is not one plain folder name, so no index record was read or written "
                + "by it. LGE never writes such a name, so check \(source).")
        }
        return name
    }

    /// The record of the set and key. A record of schema 1 reads with no `run`. A record of a schema above this build's is
    /// refused in words that name its file before the rest is read, as a set's is (`docs/formats/reference-set.md`).
    package func find(setID: String, key: String) throws -> STARIndexRecord? {
        let url = try url(setID: setID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        struct Version: Decodable { var schemaVersion: Int }
        if let found = try? JSONDecoder().decode(Version.self, from: data).schemaVersion, found > STARIndexRecord.currentSchemaVersion {
            throw STARIndexError("The index record \(url.path) has schema version \(found), and this build reads 1 and "
                + "\(STARIndexRecord.currentSchemaVersion). Read the record with the LGE that wrote it, or remove that file and adopt the index again with this build.")
        }
        let record = try JSONDecoder().decode(STARIndexRecord.self, from: data)
        if record.schemaVersion >= 2, record.run == nil {
            throw STARIndexError("The index record \(url.path) has schema version \(record.schemaVersion) and names no run, so this "
                + "build did not write it. Remove that file and adopt the index again.")
        }
        return record
    }

    /// Writes the record and the byte copy of its run record through the durable write path, the copy first and the record
    /// second, so the record is the commit point. `runRecord` is the bytes the adopt read, and a record that names a run needs
    /// them with the SHA-256 and the length it names, while a record that names none takes none. The same record again changes
    /// nothing, except that a copy which is missing or differs is written again. Another record for the same set and key is
    /// refused in words that name the record's file and what differs, since one key names one index, and a refusal writes no
    /// copy, so the copy of the run kept is never touched.
    @discardableResult
    package func write(_ record: STARIndexRecord, runRecord: Data? = nil) throws -> URL {
        let target = try url(setID: record.setID, key: record.key.folderName)
        if let run = record.run {
            guard let runRecord, PortableDigest.sha256Hex(of: runRecord) == run.runRecordSHA256,
                  UInt64(runRecord.count) == run.runRecordBytes else {
                throw STARIndexError("The index record \(target.path) names the run record with SHA-256 \(run.runRecordSHA256) "
                    + "and \(run.runRecordBytes) bytes, and the bytes given for its copy are not those, so nothing was written.")
            }
        } else if runRecord != nil {
            throw STARIndexError("The index record \(target.path) names no run, so it takes no run record and nothing was written.")
        }
        let folder = target.deletingLastPathComponent()
        let copy = folder.appendingPathComponent(STARIndexRecord.runRecordFileName)
        if let existing = try find(setID: record.setID, key: record.key.folderName) {
            guard existing == record else {
                var settled = record
                settled.schemaVersion = existing.schemaVersion
                settled.run = existing.run
                if existing.run == nil, let run = record.run, existing == settled {
                    throw STARIndexError("The index record \(target.path) was adopted before LGE kept the run that built the index, so "
                        + "it names no executor build, and it was not replaced. This adopt names the same index and the run with "
                        + "SHA-256 \(run.runRecordSHA256), built by \(Self.build(run)). To record the run, adopt with another "
                        + "--storage-root, or remove that file and adopt again.")
                }
                throw STARIndexError("The index record \(target.path) already names " + Self.differences(existing, record)
                    + ", so it was not replaced. If this run is the one to keep, remove that file and adopt again.")
            }
            if let runRecord, (try? Data(contentsOf: copy)) != runRecord {
                try DurableReplace.replace(runRecord, named: STARIndexRecord.runRecordFileName, in: folder)
            }
            return target
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let runRecord { try DurableReplace.replace(runRecord, named: STARIndexRecord.runRecordFileName, in: folder) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DurableReplace.replace(try encoder.encode(record), named: STARIndexRecord.fileName, in: folder)
        return target
    }

    /// The executor build of a run in words, its `lgeVersion` or else the binary's SHA-256.
    package static func build(_ run: STARIndexRecord.Run?) -> String {
        run?.executor.buildPin?.lgeVersion ?? run?.executor.sha256.map { "the binary with SHA-256 \($0)" } ?? "no recorded executor"
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
        var named: [String?] = [
            folders(old) == folders(new) ? nil : "its files under \(folders(old)), where this adopt names \(folders(new))",
            old.tool == new.tool && was.star == now.star ? nil : "the STAR build \(old.tool.build), where this run names \(new.tool.build)",
            was.sjdbOverhang == now.sjdbOverhang ? nil : "--sjdbOverhang \(was.sjdbOverhang), where this run names \(now.sjdbOverhang)",
            was.genomeFastaFiles == now.genomeFastaFiles ? nil : "other FASTA files",
            was.countingGTFSHA256 == now.countingGTFSHA256 ? nil : "another SHA-256 of derived/genes.gtf",
            was.gtfFilter == now.gtfFilter ? nil : "another GTF made by the 10x filter rule",
            was.referenceSetSHA256 == now.referenceSetSHA256 ? nil : "another SHA-256 of reference-set.json",
        ]
        if old.run?.runRecordSHA256 != new.run?.runRecordSHA256 {
            named.append("another run record, with SHA-256 \(old.run?.runRecordSHA256 ?? "none"), where this run names "
                + "\(new.run?.runRecordSHA256 ?? "none")")
        }
        if old.run?.executor != new.run?.executor { named.append(executorDifference(old.run, new.run)) }
        let others = named.compactMap { $0 }
        guard changed > 0 else { return "the same digests with " + (others.isEmpty ? ["other values"] : others).joined(separator: " and ") }
        return (["other digests for \(changed) of \(new.files.count) files"] + others).joined(separator: " and ")
    }

    /// The words for two runs whose executors differ, the build by its `lgeVersion` and, when that is the same, the binary.
    private static func executorDifference(_ old: STARIndexRecord.Run?, _ new: STARIndexRecord.Run?) -> String {
        let (was, now) = (build(old), build(new))
        if was != now { return "the executor build \(was), where this run names \(now)" }
        return "another executor binary, SHA-256 \(old?.executor.sha256 ?? "none"), where this run names \(new?.executor.sha256 ?? "none")"
    }
}
