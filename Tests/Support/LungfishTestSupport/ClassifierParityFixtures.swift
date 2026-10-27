// ClassifierParityFixtures.swift - Projects, databases and counts for the classifier parity replay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F2 (panel decisions T1, T2, T3 and T9 in docs/plans/2026-10-11-phase-2-7.md).
// ClassifierCLIGUIParityReplayTests runs each classifier case on several sides and compares
// them. Every side gets its own root holding one project that `makeProject(in:)` builds with
// the same bytes. The project holds four bundles, described in
// Tests/Fixtures/classifier-parity/README.md:
//
// - the classifier golden's virtual length-filter subset, built as
//   `build_virtual_bundle` in scripts/golden/captures.py builds it: a root bundle with the 100
//   reads of Tests/Fixtures/sarscov2/test_1.fastq.gz and a virtual subset of the 55 reads of
//   150 bases or more, whose preview holds the first 10 of them,
// - the read-pairing merge bundle of Tests/Fixtures/read-pairing/kraken2 (23 pairs, 77 merged),
// - the SARS-CoV-2 pair test_1 and test_2 as a paired derivative (the L5b shape of
//   ReadSetFixtures), 100 pairs,
// - the negative control, 40 synthetic reads with no viral hit,
// - the low-signal control, the negative control and five SARS-CoV-2 reads (lane A8, K6).
//
// The tools and the Kraken2 Viral database come from the Stable root that a SwiftPM test
// resolves (`~/.lungfish-stable`). The EsViritu database is read in place from
// `LUNGFISH_TEST_ESVIRITU_DB`, by default the golden environment's folder, and never written.

import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

public enum ClassifierParityFixtures {
    public static let projectName = "Project.lungfish"
    public static let rootReads = 100
    public static let subsetReads = 55
    public static let previewReads = 10
    public static let minimumLength = 150

    /// Project-relative paths of the five bundles.
    public static let subsetRootBundlePath = "Imports/sarscov2-R1.lungfishfastq"
    public static let subsetBundlePath = "Imports/sarscov2-R1.lungfishfastq/derivatives/len-150-any-00000000.lungfishfastq"
    public static let mergeBundlePath = "Imports/merge.lungfishfastq"
    public static let pairBundlePath = "Imports/sarscov2-pair.lungfishfastq"
    public static let negativeControlBundlePath = "Imports/negative-control.lungfishfastq"
    public static let lowSignalControlBundlePath = "Imports/low-signal-control.lungfishfastq"

    /// `Tests/Fixtures` of this checkout.
    public static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    // MARK: - Projects

    /// Builds `Project.lungfish` with the five bundles in `root` and returns the project.
    @discardableResult
    public static func makeProject(in root: URL) throws -> URL {
        let project = root.appendingPathComponent(projectName, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try makeSubsetBundles(in: project)
        try makeMergeBundle(at: project.appendingPathComponent(mergeBundlePath, isDirectory: true))
        try makePairBundle(at: project.appendingPathComponent(pairBundlePath, isDirectory: true))
        for (bundlePath, file) in [
            (negativeControlBundlePath, "negative-control.fastq"),
            (lowSignalControlBundlePath, "low-signal-control.fastq"),
        ] {
            let control = project.appendingPathComponent(bundlePath, isDirectory: true)
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: fixturesDirectory.appendingPathComponent("classifier-parity/\(file)"),
                to: control.appendingPathComponent(file)
            )
        }
        return project
    }

    /// The root bundle and its virtual subset, byte for byte as the golden capture writes them.
    private static func makeSubsetBundles(in project: URL) throws {
        let fileManager = FileManager.default
        let rootBundle = project.appendingPathComponent(subsetRootBundlePath, isDirectory: true)
        try fileManager.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFASTQ = rootBundle.appendingPathComponent("sarscov2-R1.fastq.gz")
        try fileManager.copyItem(at: fixturesDirectory.appendingPathComponent("sarscov2/test_1.fastq.gz"), to: rootFASTQ)

        let subset = try fastqRecords(rootFASTQ).filter { $0[1].count >= minimumLength }
        let derived = project.appendingPathComponent(subsetBundlePath, isDirectory: true)
        try fileManager.createDirectory(at: derived, withIntermediateDirectories: true)
        // seqkit seq --name --only-id writes the first word of each header.
        let readIDs = subset.map { String($0[0].dropFirst().split(whereSeparator: \.isWhitespace).first ?? "") + "\n" }
        try readIDs.joined().write(to: derived.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        let preview = subset.prefix(previewReads).map { $0.joined(separator: "\n") + "\n" }.joined()
        try preview.write(to: derived.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)

        let baseCount = subset.reduce(0) { $0 + $1[1].count }
        let operation: [String: Any] = ["createdAt": "2026-10-02T00:00:00Z", "kind": "lengthFilter", "minLength": minimumLength]
        let manifest: [String: Any] = [
            // FASTQDatasetStatistics.countsOnlyFixture(readCount:baseCount:)
            "cachedStatistics": [
                "baseCount": baseCount, "gcContent": 0, "maxReadLength": 0, "meanQuality": 0,
                "meanReadLength": Double(baseCount) / Double(subset.count), "medianReadLength": 0,
                "minReadLength": 0, "n50ReadLength": 0, "perPositionQuality": [Any](), "q20Percentage": 0,
                "q30Percentage": 0, "qualityScoreHistogram": [Any](), "readCount": subset.count,
                "readLengthHistogram": [String: Any](),
            ] as [String: Any],
            "createdAt": "2026-10-02T00:00:00Z",
            "id": "00000000-0000-4000-8000-000000000001",
            "lineage": [operation],
            "name": derived.deletingPathExtension().lastPathComponent,
            "operation": operation,
            "pairingMode": "single_end",
            "parentBundleRelativePath": "@/\(subsetRootBundlePath)",
            "payload": ["subset": ["readIDListFilename": "read-ids.txt"]],
            "rootBundleRelativePath": "@/\(subsetRootBundlePath)",
            "rootFASTQFilename": rootFASTQ.lastPathComponent,
            "schemaVersion": 2,
            "sequenceFormat": "fastq",
        ]
        var data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try data.write(to: derived.appendingPathComponent("derived.manifest.json"))
    }

    /// The merge derivative of MapReadSetReplayTests: 77 merged reads and 23 unmerged pairs.
    private static func makeMergeBundle(at bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = fixturesDirectory.appendingPathComponent("read-pairing/kraken2", isDirectory: true)
        for name in ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
        }
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 77),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 23),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 23),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "merge",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "merged.fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 123, baseCount: 30_000),
                pairingMode: .pairedEnd,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    /// The SARS-CoV-2 pair as a `fullPaired` derivative, the L5b shape that runs as a pair.
    private static func makePairBundle(at bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let sarscov2 = fixturesDirectory.appendingPathComponent("sarscov2", isDirectory: true)
        try FileManager.default.copyItem(at: sarscov2.appendingPathComponent("test_1.fastq.gz"), to: bundle.appendingPathComponent("sarscov2_R1.fastq.gz"))
        try FileManager.default.copyItem(at: sarscov2.appendingPathComponent("test_2.fastq.gz"), to: bundle.appendingPathComponent("sarscov2_R2.fastq.gz"))
        let operation = FASTQDerivativeOperation(kind: .interleaveReformat)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "sarscov2-pair",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "sarscov2_R1.fastq.gz",
                payload: .fullPaired(r1Filename: "sarscov2_R1.fastq.gz", r2Filename: "sarscov2_R2.fastq.gz"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 200, baseCount: 30_000),
                pairingMode: .pairedEnd,
                readClassification: nil,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    // MARK: - Databases and the environment

    /// The variable that names the EsViritu database folder the parity cases read.
    public static let esVirituDatabaseVariable = "LUNGFISH_TEST_ESVIRITU_DB"

    /// The golden environment's EsViritu database (docs/contracts/MACHINES.md), read only.
    public static let defaultEsVirituDatabase = URL(
        fileURLWithPath: "/Users/Shared/lungfish-golden/storage/databases/esviritu/esviritu-viral-db",
        isDirectory: true
    )

    /// The folder `LUNGFISH_TEST_ESVIRITU_DB` names, or the golden folder, or nil when it is
    /// missing.
    public static func esVirituDatabaseFolder(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let folder = environment[esVirituDatabaseVariable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultEsVirituDatabase
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return folder
    }

    /// The folder that holds the EsViritu database files, as the wizard resolves a registry
    /// entry (`EsVirituDatabaseManager.resolveDBDirectory`): the folder itself when it holds
    /// `.fna`, `.fasta`, `.fa` or `.mmi` files, else its first child that does.
    public static func esVirituDatabaseFiles(in folder: URL) -> URL? {
        func holdsDatabase(_ url: URL) -> Bool {
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return contents.contains { ["fna", "fasta", "fa", "mmi"].contains($0.pathExtension.lowercased()) }
        }
        if holdsDatabase(folder) { return folder }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first(where: holdsDatabase)
    }

    /// The Stable root's database registry, which no parity case may write.
    public static var stableRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish-stable/databases/metagenomics-db-registry.json")
    }

    /// One line per file under `folder`, with its relative path, size and modification time,
    /// sorted, so a listing taken before a run and one taken after show any write.
    public static func folderListing(_ folder: URL) throws -> [String] {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return []
        }
        var lines: [String] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(relative)\t\(values.fileSize ?? -1)\t\(modified)")
        }
        return lines.sorted()
    }

    /// The SHA-256 of a file, in lowercase hex.
    public static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Counts

    /// Each FASTQ record of a plain or gzip file as its four lines.
    public static func fastqRecords(_ url: URL) throws -> [[String]] {
        var lines: [String] = []
        try url.forEachLineAutoDecompressing { lines.append($0) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return stride(from: 0, to: lines.count - lines.count % 4, by: 4).map { Array(lines[$0..<$0 + 4]) }
    }

    /// The number of FASTQ records in a plain or gzip file.
    public static func fastqRecordCount(_ url: URL) throws -> Int {
        try fastqRecords(url).count
    }

    /// The reads a Kraken2 report counts, classified (the clade of root, taxid 1) and
    /// unclassified (taxid 0). Reads the standard and the minimizer column layouts.
    public static func kreportTotals(_ url: URL) throws -> (classified: Int, unclassified: Int) {
        var classified = 0
        var unclassified = 0
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6 else { continue }
            let taxidField = fields.count >= 8 ? fields[6] : fields[4]
            guard let reads = Int(fields[1]) else { continue }
            switch taxidField {
            case "0": unclassified = reads
            case "1": classified = reads
            default: continue
            }
        }
        return (classified, unclassified)
    }

    /// The viruses and families of an EsViritu `<sample>.detected_virus.info.tsv`, as the GUI
    /// counts them for its row: the distinct accessions of its data rows, and the distinct
    /// families among them, leaving out empty, `NA` and `none` families. Throws when the header
    /// lacks either column.
    public static func esVirituDetections(_ url: URL) throws -> (viruses: Int, families: Int) {
        func fields(_ line: String) -> [String] {
            line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        guard let header = lines.first.map(fields),
              let accession = header.firstIndex(of: "Accession"),
              let family = header.firstIndex(of: "family") else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        var accessions: Set<String> = []
        var families: Set<String> = []
        for row in lines.dropFirst().map(fields) where row.count > max(accession, family) && !row[accession].isEmpty {
            accessions.insert(row[accession])
            if !["", "na", "none"].contains(row[family].lowercased()) { families.insert(row[family]) }
        }
        return (accessions.count, families.count)
    }

    /// The `name: count` lines of an EsViritu `_esviritu.readstats.yaml`.
    public static func esVirituReadStats(_ url: URL) throws -> [String: Int] {
        var stats: [String: Int] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Int(parts[1]) { stats[parts[0]] = value }
        }
        return stats
    }
}
