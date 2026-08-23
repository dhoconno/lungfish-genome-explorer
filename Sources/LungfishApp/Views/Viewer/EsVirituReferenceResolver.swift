// EsVirituReferenceResolver.swift - Resolves the EsViritu pangenome reference for alignment evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// Finds the managed EsViritu pangenome FASTA that a result was aligned against.
///
/// EsViritu maps reads onto one large pangenome FASTA belonging to a managed
/// database version. That FASTA is shared by every result and deliberately never
/// copied into any of them, so the EsViritu leaf cannot find it on its own; this
/// resolver runs in `LungfishApp` and is handed to the leaf as a callback.
///
/// Fidelity to the recorded version is the point. A detection's coordinates and
/// contig name belong to the database the run actually used, so the resolver
/// reads that path back out of the result's own `esviritu-result.json` sidecar.
/// When that version is no longer installed it substitutes the installed one, but
/// always with a reason the viewport can show; it never quietly swaps in a
/// different reference.
struct EsVirituReferenceResolver {

    /// The outcome of a lookup: the candidate to validate, plus an explanation
    /// whenever the answer is anything other than the exact recorded database.
    struct Resolution {
        let candidate: ClassifierAlignmentReferenceCandidate?
        let reason: String?

        static let unresolved = Resolution(candidate: nil, reason: nil)
    }

    /// Filenames the EsViritu database ships its pangenome under, most specific first.
    private static let pangenomeFilenames = ["virus_pathogen_database.fna"]

    /// Extensions accepted when the canonical filename is absent, so a renamed or
    /// repackaged database still resolves rather than silently losing its reference.
    private static let pangenomeExtensions = ["fna", "fasta", "fa"]

    private let databaseRootURL: URL
    private let fileManager: FileManager

    init(
        databaseRootURL: URL = ManagedStorageConfigStore().currentLocation().databaseRootURL,
        fileManager: FileManager = .default
    ) {
        self.databaseRootURL = databaseRootURL
        self.fileManager = fileManager
    }

    /// The EsViritu subtree of the managed databases root.
    private var esVirituRoot: URL {
        databaseRootURL.appendingPathComponent("esviritu", isDirectory: true)
    }

    /// Resolves the reference for one detection row.
    ///
    /// - Parameters:
    ///   - resultURL: The result directory (batch root, or a single-sample result).
    ///   - sampleID: The sample whose sidecar records the database used.
    ///   - contig: The BAM contig name, which is also the FASTA record name.
    ///   - length: The contig length reported by the detection row.
    func resolve(resultURL: URL, sampleID: String, contig: String, length: Int) -> Resolution {
        guard !contig.isEmpty, length > 0 else { return .unresolved }

        let recorded = recordedDatabasePath(resultURL: resultURL, sampleID: sampleID)

        if let recorded, let fasta = pangenomeFASTA(in: recorded) {
            return Resolution(
                candidate: candidate(fastaURL: fasta, contig: contig, length: length),
                reason: nil
            )
        }

        guard let installed = installedDatabaseDirectory(), let fasta = pangenomeFASTA(in: installed) else {
            let reason = if let recorded {
                "The EsViritu database this result used (\(Self.versionLabel(recorded))) is not installed, and no other EsViritu database was found."
            } else {
                "No installed EsViritu database was found, so the reference sequence is unavailable."
            }
            return Resolution(candidate: nil, reason: reason)
        }

        let reason = if let recorded {
            "The EsViritu database this result used (\(Self.versionLabel(recorded))) is no longer installed; showing the installed database \(Self.versionLabel(installed)) instead."
        } else {
            "This result did not record which EsViritu database it used; showing the installed database \(Self.versionLabel(installed))."
        }
        return Resolution(
            candidate: candidate(fastaURL: fasta, contig: contig, length: length),
            reason: reason
        )
    }

    private func candidate(fastaURL: URL, contig: String, length: Int) -> ClassifierAlignmentReferenceCandidate {
        ClassifierAlignmentReferenceCandidate(
            fastaURL: fastaURL,
            recordName: contig,
            expectedLength: length
        )
    }

    // MARK: - Recorded database

    /// Reads the database path out of the result's own sidecar.
    ///
    /// Batch results keep one sidecar per sample subdirectory; a single-sample run
    /// keeps it at the result root. Any sample's sidecar in a batch names the same
    /// database, so an unmatched sample ID still resolves via the first sidecar
    /// found rather than falling all the way through to the installed database.
    private func recordedDatabasePath(resultURL: URL, sampleID: String) -> URL? {
        var searched: [URL] = []
        if !sampleID.isEmpty {
            searched.append(resultURL.appendingPathComponent(sampleID, isDirectory: true))
            searched.append(
                resultURL.appendingPathComponent(
                    MetagenomicsSampleGrouper.sanitizeSampleId(sampleID),
                    isDirectory: true
                )
            )
        }
        searched.append(resultURL)

        for directory in searched {
            if let path = databasePath(inSidecarAt: directory) { return path }
        }

        // Fall back to any sample subdirectory of the batch: the whole batch ran
        // against one database, so a sample-ID mismatch must not lose the version.
        let contents = (try? fileManager.contentsOfDirectory(
            at: resultURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for subdirectory in contents.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: subdirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if let path = databasePath(inSidecarAt: subdirectory) { return path }
        }
        return nil
    }

    private func databasePath(inSidecarAt directory: URL) -> URL? {
        let sidecar = directory.appendingPathComponent("esviritu-result.json")
        guard let data = try? Data(contentsOf: sidecar),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let raw = config["databasePath"] as? String,
              !raw.isEmpty
        else { return nil }
        // `URL` encodes as an absolute file URL string, but tolerate a bare path.
        let url = URL(string: raw).flatMap { $0.isFileURL ? $0 : nil }
            ?? URL(fileURLWithPath: raw)
        return url.standardizedFileURL
    }

    // MARK: - Installed database

    /// The deepest installed EsViritu database directory, preferring the newest
    /// version when several are present.
    private func installedDatabaseDirectory() -> URL? {
        var candidates: [URL] = []
        for base in [esVirituRoot.appendingPathComponent("esviritu-viral-db", isDirectory: true), esVirituRoot] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            if pangenomeFASTA(in: base) != nil { candidates.append(base) }
            for entry in contents where pangenomeFASTA(in: entry) != nil {
                candidates.append(entry)
            }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in
            lhs.lastPathComponent.compare(rhs.lastPathComponent, options: .numeric) == .orderedAscending
        }.last
    }

    /// The pangenome FASTA inside a database directory, if it holds one.
    private func pangenomeFASTA(in directory: URL) -> URL? {
        for name in Self.pangenomeFilenames {
            let url = directory.appendingPathComponent(name)
            if fileManager.isReadableFile(atPath: url.path) { return url }
        }
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { Self.pangenomeExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// A short human label for a database directory, used in fallback reasons.
    private static func versionLabel(_ directory: URL) -> String {
        let name = directory.lastPathComponent
        return name.isEmpty ? directory.path : name
    }
}
