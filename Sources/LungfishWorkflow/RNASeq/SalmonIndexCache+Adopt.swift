// SalmonIndexCache+Adopt.swift - A served salmon index adopted into the cache (2026-11-27)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The owner directed on 2026-11-27 that the catalog's indexes be served instead of built on every Mac
// (`docs/plans/2026-11-27-rnaseq-served-salmon-index.md`). Two builds of one set with one salmon build give the same
// bytes, so a served index is the index this Mac would build when its set id and salmon build are the ones the index
// names. The archive holds `index/` and `index-key.json` only. The cache writes the record itself, so no path of the
// Mac that built it is served, and the record says the index was adopted and from which archive.

import Foundation
import LungfishCore

/// One served index: the archive and the key it was built for, copied from that build's `index-key.json`.
package struct ServedSalmonIndex: Sendable, Equatable {
    package var url: String
    package var archiveBytes: Int64
    package var archiveSHA256: String
    /// The bytes of `index/` once unpacked, for the disk check.
    package var unpackedBytes: Int64
    package var setID: String
    /// `<name>-<version>-<build>` of the salmon that built it, as `index-key.json` names it.
    package var salmonBuild: String
    package var k: Int
    package var decoys: SalmonIndexDecoys

    package init(
        url: String, archiveBytes: Int64, archiveSHA256: String, unpackedBytes: Int64, setID: String, salmonBuild: String,
        k: Int, decoys: SalmonIndexDecoys
    ) {
        self.url = url
        self.archiveBytes = archiveBytes
        self.archiveSHA256 = archiveSHA256
        self.unpackedBytes = unpackedBytes
        self.setID = setID
        self.salmonBuild = salmonBuild
        self.k = k
        self.decoys = decoys
    }
}

extension SalmonIndexCache {
    /// The local salmon's package line, which the served path compares with `ServedSalmonIndex.salmonBuild`.
    package func localSalmonBuild() async throws -> String {
        try await salmonVersion().build
    }

    /// Adopts the served index in `archive` for its set. A published index of the same key is used as it is. Every check
    /// runs before the stage is renamed into place, and a failed one publishes nothing.
    ///
    /// - Throws: ``SalmonIndexError`` or the error of a write.
    package func adopt(archive: URL, served: ServedSalmonIndex, argv: [String] = []) async throws -> SalmonIndexOutcome {
        let started = Date()
        let owner = ReferenceSetOwner(storageRoot: storageRoot)
        let setURL = owner.setsFolder.appendingPathComponent(
            "\(served.setID).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: setURL.path) else {
            throw SalmonIndexError.noSet(id: served.setID, folder: owner.setsFolder.path)
        }
        let set = try owner.settled(setURL, id: served.setID)
        let salmon = try await salmonVersion()
        guard salmon.build == served.salmonBuild else {
            throw SalmonIndexError.servedIndexDiffers(
                "The served index was built by \(served.salmonBuild), and this Mac's salmon is \(salmon.build).")
        }
        let key = SalmonIndexKey(setID: served.setID, salmonVersion: salmon.version, k: served.k, decoys: served.decoys)
        if let found = try published(key) { return found }

        try Self.checkServedArchive(archive, served: served)
        removeAbandonedStages()
        let setFolder = cacheFolder.appendingPathComponent(key.setID, isDirectory: true)
        try FileManager.default.createDirectory(at: setFolder, withIntermediateDirectories: true)
        let hold = try SalmonIndexStageHold.make(in: setFolder, name: key.folderName)
        defer { hold.release() }
        let finalURL = folder(for: key)
        var renaming = false
        do {
            try await SafeZipExtractor().extract(archive, to: hold.url)
            let file = try servedKeyFile(in: hold.url, key: key, served: served, set: set)
            var envelope = try makeEnvelope(file, set: set, finalURL: finalURL, stage: hold.url, argv: argv, started: started)
            envelope.workflowName = "RNA-seq salmon index, served"
            envelope.options = ProvenanceOptions(
                explicit: envelope.options.explicit.merging([
                    "served_index_url": .string(served.url), "served_index_sha256": .string(served.archiveSHA256),
                ]) { $1 },
                defaults: envelope.options.defaults, resolvedDefaults: envelope.options.resolvedDefaults)
            try provenanceWriter.write(envelope, to: hold.url, bundleLayoutRoot: finalURL)
            try provenanceWriter.writeBundleProvenanceLayout(envelope, toBundleRoot: hold.url, descriptorBundleRoot: finalURL)
            try FileManager.default.createDirectory(
                at: hold.url.appendingPathComponent(Self.usesFolderName, isDirectory: true), withIntermediateDirectories: false)
            renaming = true
            try PortableRename.exclusive(hold.url, to: finalURL)
            return SalmonIndexOutcome(url: finalURL, key: key, hashes: file.hashes, reused: false)
        } catch {
            try? FileManager.default.removeItem(at: hold.url)
            if renaming, FileManager.default.fileExists(atPath: finalURL.path) { return try settled(finalURL, key: key) }
            throw error
        }
    }

    /// The archive's size and sha256 are the row's, and it holds `index/` and `index-key.json` and nothing else.
    static func checkServedArchive(_ archive: URL, served: ServedSalmonIndex) throws {
        let bytes = archive.fileSizeBytes
        guard bytes == served.archiveBytes else {
            throw SalmonIndexError.servedIndexDiffers("The archive has \(bytes) bytes, not \(served.archiveBytes).")
        }
        let found = try FileDigest.sha256(of: archive) { try Task.checkCancellation() }
        guard found == served.archiveSHA256 else {
            throw SalmonIndexError.servedIndexDiffers("The archive has sha256 \(found), not \(served.archiveSHA256).")
        }
        let entries = try SafeZipExtractor.readCentralDirectory(of: archive)
        let stray = entries.filter { !$0.isDirectory } + entries.filter(\.isDirectory)
        if let entry = stray.first(where: {
            !($0.path == SalmonIndexKeyFile.filename || $0.path.hasPrefix("\(indexFolderName)/")) || $0.isSymbolicLink
        }) {
            throw SalmonIndexError.servedIndexDiffers("The archive holds \(entry.path), which a served index never holds.")
        }
    }

    /// The unpacked `index-key.json` names this key, the served salmon build and this Mac's set manifest, and salmon's
    /// `info.json` gives the same k, version and hashes.
    func servedKeyFile(
        in stage: URL, key: SalmonIndexKey, served: ServedSalmonIndex, set: ReferenceSetOutcome
    ) throws -> SalmonIndexKeyFile {
        guard let data = try? Data(contentsOf: stage.appendingPathComponent(SalmonIndexKeyFile.filename)),
              let file = try? JSONDecoder().decode(SalmonIndexKeyFile.self, from: data) else {
            throw SalmonIndexError.servedIndexDiffers("The archive's \(SalmonIndexKeyFile.filename) could not be read.")
        }
        let manifest = try ProvenanceFileHasher.sha256(of: set.url.appendingPathComponent(ReferenceSetManifest.filename))
        let checks = [
            ("key", "\(key)", "\(file.key)"), ("salmon build", served.salmonBuild, file.salmonBuild),
            ("set manifest sha256", manifest, file.referenceSetSHA256),
        ]
        for (field, expected, found) in checks where expected != found {
            throw SalmonIndexError.servedIndexDiffers("The archive's \(SalmonIndexKeyFile.filename) gives \(field) \(found), not \(expected).")
        }
        let info = stage.appendingPathComponent("\(Self.indexFolderName)/info.json")
        guard let infoData = try? Data(contentsOf: info),
              let object = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
            throw SalmonIndexError.servedIndexDiffers("The archive holds no readable index/info.json.")
        }
        let given: [(String, String?, String?)] = [
            ("k", String(file.k), (object["k"] as? NSNumber)?.stringValue),
            ("salmon_version", file.salmonVersion, object["salmon_version"] as? String),
            ("seq_hash", file.indexSeqHash, object["seq_hash"] as? String),
            ("name_hash", file.indexNameHash, object["name_hash"] as? String),
            ("decoy_seq_hash", file.indexDecoySeqHash, object["decoy_seq_hash"] as? String),
            ("decoy_name_hash", file.indexDecoyNameHash, object["decoy_name_hash"] as? String),
        ]
        for (field, expected, found) in given where expected != found {
            throw SalmonIndexError.indexDisagrees(field: field, expected: expected ?? "none", found: found ?? "none")
        }
        return file
    }
}
