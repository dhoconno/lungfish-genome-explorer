// ReferenceSetCatalog.swift - The reference sets the Plugin Manager installs, and what is installed of each (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The novice path of 2026-11-26 (`docs/reports/2026-11-26-rnaseq-novice-path/`): a beginner installs a reference set
// from Plugin Manager > Databases instead of building one in Terminal. Each entry is a named default row, so the URLs and
// sha256 pins stay in `ReferenceSetDefaults.swift` alone.

import Foundation
import LungfishCore

/// One reference set the Databases tab offers.
package struct ReferenceSetCatalogEntry: Sendable, Equatable, Identifiable {
    /// The named default row, such as `human/gencode-50`.
    package var id: String
    /// What the row shows, organism first, because a beginner chooses by organism.
    package var title: String
    /// The bytes of the genome and GTF downloads together.
    package var downloadBytes: Int64
    /// The index served for the set these files build, nil when the Mac builds it (plan of 2026-11-27).
    package var servedIndex: ServedSalmonIndex? = nil
    /// The disk space the set uses once installed: the set, its unpacked index and the kept genome and GTF, measured on
    /// galah with du on 2026-11-27. It is the only figure the Plugin Manager row shows (owner, 2026-11-27).
    package var installedBytes: Int64 = 0

    /// The memory the install checks: a count's when the index is served, the index build's otherwise.
    package var memoryNeedBytes: Int64 {
        servedIndex == nil ? SalmonIndexNeed.peakMemoryBytes : SalmonQuantNeed.peakMemoryBytes
    }

    package var row: ReferenceSetDefault {
        // Every entry names a row of `ReferenceSetDefault.all`, which `ReferenceSetCatalogTests` checks.
        ReferenceSetDefault.all.first { $0.id == id }!
    }
}

/// What the storage root holds of one entry.
package enum ReferenceSetInstallState: Sendable, Equatable {
    case notInstalled
    /// The set is there but its k 31 genome-decoy salmon index is not, so the quantify step would stop.
    case setWithoutIndex(setID: String)
    case ready(setID: String)

    package var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

package enum ReferenceSetCatalog {
    // The macaque entries are each species' default row of P5-REFS (owner, 2026-11-27): Ensembl 116 for rhesus, the
    // same Ensembl release as GENCODE 50 and M39, and the T2T RefSeq assembly for cynomolgus. Each serves its index from
    // the public LGE LabKey area (owner, 2026-11-27), archived by `scripts/rnaseq/serve-index.py` from galah's build
    // (`docs/plans/2026-11-27-rnaseq-served-salmon-index.md`).
    package static let entries: [ReferenceSetCatalogEntry] = [
        ReferenceSetCatalogEntry(
            id: "human/gencode-50", title: "Human, GRCh38 with GENCODE 50", downloadBytes: 970_285_312,
            servedIndex: served(set: "homo_sapiens-GRCh38-gencode50-lge-c287524e9a53", bytes: 5_817_381_408,
                                sha256: "b0d09323c726c37a244b8b35fdae96f787086b0d41cefff13b71274c4a967a0b", contents: "246a7b2a877b4e931aa61f9eff9191f846b356938e5155b6e9c85527a6e82798",
                                unpacked: 10_505_298_684), installedBytes: 18_600_000_000),
        ReferenceSetCatalogEntry(
            id: "mouse/gencode-M39", title: "Mouse, GRCm39 with GENCODE M39", downloadBytes: 866_420_506,
            servedIndex: served(set: "mus_musculus-GRCm39-gencodem39-lge-398effa30daf", bytes: 4_398_536_780,
                                sha256: "457e1402928324405620a89f3016dae95d646803125850c25dbcffebdb2abbb7", contents: "aba24fc71a42ffb68fd2685ab920e4cb5e7a1b25fbe6bd5016580434c74dc685",
                                unpacked: 8_694_199_814), installedBytes: 15_000_000_000),
        ReferenceSetCatalogEntry(
            id: "rhesus/ensembl-116", title: "Rhesus macaque, Mmul_10 with Ensembl 116", downloadBytes: 892_739_343,
            servedIndex: served(set: "macaca_mulatta-Mmul_10-ensembl116-lge-3f0fee25ce9e", bytes: 5_275_380_007,
                                sha256: "c870d7d3338c499ae3dd15c20bad64e47f8e390bce7742e7dd94a1ee87e8e27a", contents: "3ee11b2e9b3e820bc93814e902fe1279a28e09191e7316a013cef5fd73d83319",
                                unpacked: 8_449_585_883), installedBytes: 10_900_000_000),
        ReferenceSetCatalogEntry(
            id: "cynomolgus/refseq-GCF_037993035.2", title: "Cynomolgus macaque, T2T-MFA8v1.1 with RefSeq", downloadBytes: 954_363_387,
            servedIndex: served(set: "macaca_fascicularis-T2T-MFA8v1.1-refseqrs_2025_03-lge-b514efeeb33d", bytes: 5_875_003_363,
                                sha256: "e7e702bab69248a44d4da29174d84c149c08ddf904c9d1fcc59f13cab1688c3d", contents: "8598db49e086f66b1269c9146d2b1e5b7a30712326aafa294f974336af60f2ca",
                                unpacked: 9_602_008_677), installedBytes: 13_500_000_000),
    ]

    /// The public LGE LabKey folder of the served indexes (`docs/development/large-files.md`).
    package static let servedIndexBase = "https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/databases/rnaseq-index/"

    /// A served index of `set` built by salmon 2.11.0 at k 31 with genome decoys, at its folder of the public area.
    /// `contents` is `ReferenceSetManifest.contentSHA256(of:)` of galah's set, measured 2026-11-27.
    static func served(set: String, bytes: Int64, sha256: String, contents: String, unpacked: Int64) -> ServedSalmonIndex {
        let key = "salmon-2.11.0-k31-genome-decoys"
        return ServedSalmonIndex(
            url: servedIndexBase + "\(set)/\(key)/\(set)-\(key).zip", archiveBytes: bytes, archiveSHA256: sha256,
            unpackedBytes: unpacked, setID: set, setContentSHA256: contents, salmonBuild: "salmon-2.11.0-hfc06a8d_0", k: 31, decoys: .genome)
    }

    package static let description = "Genome, genes and salmon index for counting bulk RNA-seq reads."

    /// The one index the catalog builds and the quantify pane's defaults name (BIO ruling 2026-11-26, item 4).
    package static let indexK = 31
    package static let indexDecoys = SalmonIndexDecoys.genome
    /// The memory the index build is checked against (`SalmonIndexNeed.peakMemoryBytes`).
    package static let indexMemoryBytes = SalmonIndexNeed.peakMemoryBytes

    package static func entry(_ id: String) -> ReferenceSetCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// What `storageRoot` holds of `entry`. It reads the manifests and folder names only, never hashes a file and
    /// starts no process, so the app can call it off the main actor whenever the tab appears.
    ///
    /// A set counts as the entry's when its manifest records the row's genome and GTF sha256, in LGE's layout, with no
    /// extras. The id is not compared, since it hashes the gffread and derive versions (BIO trap 4).
    package static func state(of entry: ReferenceSetCatalogEntry, storageRoot: URL) -> ReferenceSetInstallState {
        state(pins: entry.row, storageRoot: storageRoot)
    }

    /// What `storageRoot` holds of the set that `row` pins.
    package static func state(pins row: ReferenceSetDefault, storageRoot: URL) -> ReferenceSetInstallState {
        let sets = storageRoot.appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sets.path) else { return .notInstalled }
        var found: String?
        for name in names.sorted() where !name.hasPrefix(".") && name.hasSuffix("." + ReferenceSetManifest.folderExtension) {
            guard let manifest = try? ReferenceSetManifest.load(from: sets.appendingPathComponent(name, isDirectory: true)),
                  manifest.genome.sha256 == row.genomeSHA256, manifest.annotation.sha256 == row.annotationSHA256,
                  manifest.extras.isEmpty, manifest.layout.kind == "lge"
            else { continue }
            if hasIndex(setID: manifest.id, storageRoot: storageRoot) { return .ready(setID: manifest.id) }
            found = found ?? manifest.id
        }
        return found.map { .setWithoutIndex(setID: $0) } ?? .notInstalled
    }

    /// Whether a published k 31 genome-decoy index of `setID` is there, of any salmon version. The key file and
    /// `index/info.json` are what `SalmonIndexCache.settled` checks first.
    package static func hasIndex(setID: String, storageRoot: URL) -> Bool {
        let folder = storageRoot.appendingPathComponent(SalmonIndexCache.folderName, isDirectory: true)
            .appendingPathComponent(setID, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let suffix = "-k\(indexK)-\(indexDecoys.rawValue)"
        return names.contains { name in
            name.hasPrefix("salmon-") && name.hasSuffix(suffix)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("\(name)/\(SalmonIndexCache.indexFolderName)/info.json").path)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("\(name)/\(SalmonIndexKeyFile.filename)").path)
        }
    }
}
