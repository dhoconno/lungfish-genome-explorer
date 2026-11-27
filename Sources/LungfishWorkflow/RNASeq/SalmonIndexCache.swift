// SalmonIndexCache.swift - The one owner of `<storage root>/rnaseq-index-cache/` (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// It builds, settles, records the uses of and removes every salmon index (`docs/formats/reference-set.md`, section The
// salmon index cache). A key folder `<set id>/salmon-<version>-k<k>-<decoys>/` that is there is reused with no process.
// Otherwise it removes each stage no running build holds, checks the Mac's memory and free disk, writes the gentrome and
// the decoy names in a held stage, runs `salmon index`, checks salmon's `info.json` against the key, writes
// `index-key.json` and the root record last and renames the stage into place with `RENAME_EXCL`.

import Foundation
import LungfishCore

/// Whether the genome goes into the index as decoys.
public enum SalmonIndexDecoys: String, Codable, Sendable, CaseIterable {
    case genome = "genome-decoys"
    case none = "no-decoys"
}

/// What names one index: the set, the salmon version that built it, k and the decoys. Nothing else a build passes is in
/// the key, since every build passes the same options (`SalmonIndexNeed`).
public struct SalmonIndexKey: Codable, Sendable, Hashable {
    public var setID: String
    public var salmonVersion: String
    public var k: Int
    public var decoys: SalmonIndexDecoys

    public init(setID: String, salmonVersion: String, k: Int, decoys: SalmonIndexDecoys) {
        self.setID = setID
        self.salmonVersion = salmonVersion
        self.k = k
        self.decoys = decoys
    }

    public var folderName: String { "salmon-\(salmonVersion)-k\(k)-\(decoys.rawValue)" }
}

public struct SalmonIndexRequest: Sendable, Equatable {
    public var setID: String
    public var k: Int
    public var decoys: SalmonIndexDecoys

    public init(setID: String, k: Int = 31, decoys: SalmonIndexDecoys = .genome) {
        self.setID = setID
        self.k = k
        self.decoys = decoys
    }
}

/// The four hashes salmon writes in `info.json`, under the names `meta_info.json` gives them. The decoy pair is nil for an
/// index with no decoys.
public struct SalmonIndexHashes: Codable, Sendable, Equatable {
    public var seqHash: String
    public var nameHash: String
    public var decoySeqHash: String?
    public var decoyNameHash: String?

    public init(seqHash: String, nameHash: String, decoySeqHash: String?, decoyNameHash: String?) {
        self.seqHash = seqHash
        self.nameHash = nameHash
        self.decoySeqHash = decoySeqHash
        self.decoyNameHash = decoyNameHash
    }

    /// Each hash the index has, in the order of `meta_info.json`.
    public var all: [String] { [seqHash, nameHash] + [decoySeqHash, decoyNameHash].compactMap { $0 } }
}

public struct SalmonIndexOutcome: Sendable, Equatable {
    /// The key folder.
    public var url: URL
    public var key: SalmonIndexKey
    public var hashes: SalmonIndexHashes
    /// True when a published index of the same key was used and nothing was built.
    public var reused: Bool

    /// The folder salmon wrote, which `salmon quant -i` reads.
    public var indexURL: URL { url.appendingPathComponent("index", isDirectory: true) }
}

/// `index-key.json`: the key, the set's manifest sha256, salmon's build, the arguments salmon ran with and the hashes.
public struct SalmonIndexKeyFile: Codable, Sendable, Equatable {
    public static let filename = "index-key.json"
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var setID: String
    public var salmonVersion: String
    public var k: Int
    public var decoys: SalmonIndexDecoys
    public var referenceSetSHA256: String
    /// `<name>-<version>-<build>` of the conda package that ran.
    public var salmonBuild: String
    /// salmon's arguments, with the stage's files named by their names in it.
    public var argv: [String]
    public var indexSeqHash: String
    public var indexNameHash: String
    public var indexDecoySeqHash: String?
    public var indexDecoyNameHash: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, setID, salmonVersion, k, decoys, referenceSetSHA256, salmonBuild, argv
        case indexSeqHash = "index_seq_hash", indexNameHash = "index_name_hash"
        case indexDecoySeqHash = "index_decoy_seq_hash", indexDecoyNameHash = "index_decoy_name_hash"
    }

    public var key: SalmonIndexKey { SalmonIndexKey(setID: setID, salmonVersion: salmonVersion, k: k, decoys: decoys) }

    public var hashes: SalmonIndexHashes {
        SalmonIndexHashes(seqHash: indexSeqHash, nameHash: indexNameHash, decoySeqHash: indexDecoySeqHash,
                          decoyNameHash: indexDecoyNameHash)
    }
}

public enum SalmonIndexError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case noSet(id: String, folder: String)
    case versionUnknown(environment: String)
    case salmonFailed(status: Int, stderr: String)
    case indexDisagrees(field: String, expected: String, found: String)
    case publishedIndexDiffers(path: String)
    case notFound(path: String)
    case inUse(index: String, results: [String])
    /// A served index that is not the one its row names, so nothing was published.
    case servedIndexDiffers(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let words):
            return words
        case .noSet(let id, let folder):
            return "No reference set \(id) is in \(folder). Build the set first, then its index."
        case .versionUnknown(let environment):
            return "Lungfish could not read the version of salmon from its environment at \(environment), so it cannot name "
                + "the index. Install the RNA-seq pack in the Plugin Manager again."
        case .salmonFailed(let status, let stderr):
            return "salmon index stopped with exit status \(status) and Lungfish published nothing. Its last lines were:\n"
                + "\(stderr)\nFix what they name and run the same command again."
        case .indexDisagrees(let field, let expected, let found):
            return "salmon wrote an index whose info.json gives \(field) \(found), not \(expected), so Lungfish published nothing."
        case .publishedIndexDiffers(let path):
            return "The index at \(path) does not match its \(SalmonIndexKeyFile.filename). Remove that folder and build the index again."
        case .notFound(let path):
            return "There is no index at \(path)."
        case .servedIndexDiffers(let reason):
            return reason
        case .inUse(let index, let results):
            let count = results.count == 1 ? "a result" : "\(results.count) results"
            return "The index at \(index) stays, because \(count) still name it: \(results.joined(separator: ", ")). "
                + "Remove or move those results first."
        }
    }
}

/// The one writer under `<storage root>/rnaseq-index-cache/`.
public struct SalmonIndexCache: Sendable {
    public static let folderName = "rnaseq-index-cache"
    public static let indexFolderName = "index"
    static let workFolderName = ".work"
    static let gentromeName = "gentrome.fa"
    static let decoysName = "decoys.txt"

    public let cacheFolder: URL
    let storageRoot: URL
    let runner: NativeToolRunner
    let provenanceWriter: ProvenanceWriter
    let host: RunFitHostFacts
    let freeSpace: RunFitPreflight.FreeSpaceReader

    /// `host` is the caller's reading, `Int64(clamping: ProcessInfo.processInfo.physicalMemory)` (ADJ-SPIKE-ARCH item 3).
    package init(
        storageRoot: URL, runner: NativeToolRunner = .shared, provenanceWriter: ProvenanceWriter = ProvenanceWriter(),
        host: RunFitHostFacts, freeSpace: @escaping RunFitPreflight.FreeSpaceReader = RunFitPreflight.volumeFreeSpace
    ) {
        self.storageRoot = storageRoot
        cacheFolder = ManagedStorageLocation(rootURL: storageRoot).rootURL.appendingPathComponent(Self.folderName, isDirectory: true)
        self.runner = runner
        self.provenanceWriter = provenanceWriter
        self.host = host
        self.freeSpace = freeSpace
    }

    public func folder(for key: SalmonIndexKey) -> URL {
        cacheFolder.appendingPathComponent(key.setID, isDirectory: true).appendingPathComponent(key.folderName, isDirectory: true)
    }

    /// The published index of `key` after its key file is checked, nil when none is there. It starts no process.
    public func published(_ key: SalmonIndexKey) throws -> SalmonIndexOutcome? {
        let url = folder(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try settled(url, key: key)
    }

    /// A published index whose `index-key.json` names this key and whose `index/info.json` is there.
    func settled(_ url: URL, key: SalmonIndexKey) throws -> SalmonIndexOutcome {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(SalmonIndexKeyFile.filename)),
              let file = try? JSONDecoder().decode(SalmonIndexKeyFile.self, from: data), file.key == key,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("\(Self.indexFolderName)/info.json").path)
        else { throw SalmonIndexError.publishedIndexDiffers(path: url.path) }
        return SalmonIndexOutcome(url: url, key: key, hashes: file.hashes, reused: true)
    }
}
