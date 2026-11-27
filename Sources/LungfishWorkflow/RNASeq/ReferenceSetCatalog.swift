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
    package static let entries: [ReferenceSetCatalogEntry] = [
        ReferenceSetCatalogEntry(id: "human/gencode-50", title: "Human, GRCh38 with GENCODE 50", downloadBytes: 970_285_312),
        ReferenceSetCatalogEntry(id: "mouse/gencode-M39", title: "Mouse, GRCm39 with GENCODE M39", downloadBytes: 866_420_506),
        // The macaque entries are each species' default row of P5-REFS (owner, 2026-11-27): Ensembl 116 for rhesus, the
        // same Ensembl release as GENCODE 50 and M39, and the T2T RefSeq assembly for cynomolgus.
        ReferenceSetCatalogEntry(id: "rhesus/ensembl-116", title: "Rhesus macaque, Mmul_10 with Ensembl 116", downloadBytes: 892_739_343),
        ReferenceSetCatalogEntry(id: "cynomolgus/refseq-GCF_037993035.2", title: "Cynomolgus macaque, T2T-MFA8v1.1 with RefSeq",
                                 downloadBytes: 954_363_387),
    ]

    package static let description = "Genome, genes and salmon index for counting bulk reads."

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
