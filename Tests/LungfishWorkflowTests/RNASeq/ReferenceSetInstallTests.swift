// ReferenceSetInstallTests.swift - The catalog install: download, check, build the set, build the index (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import XCTest
@testable import LungfishWorkflow

/// A loader that copies a file URL and counts its downloads, so no test touches the network.
final class CopyingArchiveLoader: DemoProjectArchiveLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [String] = []
    var downloads: [String] { lock.withLock { fetched } }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        lock.withLock { fetched.append(url.lastPathComponent) }
        try FileManager.default.copyItem(at: url, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        progress(size, size)
    }
}

final class ReferenceSetInstallTests: XCTestCase {
    var base: URL!
    var root: URL!
    var sources: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("refinstall-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        sources = base.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data(ReferenceSetOwnerTests.genome.utf8).write(to: sources.appendingPathComponent("test.genome.fa"))
        try Data(ReferenceSetOwnerTests.annotation.utf8).write(to: sources.appendingPathComponent("test.annotation.gtf"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func row(genomeSHA: String? = nil) throws -> ReferenceSetDefault {
        let genome = sources.appendingPathComponent("test.genome.fa"), gtf = sources.appendingPathComponent("test.annotation.gtf")
        return ReferenceSetDefault.row(
            "test/one", "test", "Testus examplus", "T1", nil, "TestDB", "7",
            genome.absoluteString, try genomeSHA ?? FileDigest.sha256(of: genome),
            gtf.absoluteString, try FileDigest.sha256(of: gtf))
    }

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var indexed: [String] = []
        func note(_ id: String) { lock.withLock { indexed.append(id) } }
    }

    func installer(_ loader: CopyingArchiveLoader, calls: Calls = Calls(), refuse: Bool = false) -> ReferenceSetInstall {
        let root = self.root!
        return ReferenceSetInstall(
            storageRoot: root, loader: loader,
            owner: ReferenceSetOwner(storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil)),
            indexer: { setID, _ in
                calls.note(setID)
                return root.appendingPathComponent("index-of-\(setID)")
            },
            preflight: {
                if refuse { throw RunFitError.insufficientMemory(needBytes: 2, haveBytes: 1, basis: "test", linuxRoute: "Use Linux") }
            })
    }

    func testAnInstallDownloadsChecksBuildsTheSetAndIndexesItAndKeepsTheDownloads() async throws {
        let loader = CopyingArchiveLoader(), calls = Calls()
        let outcome = try await installer(loader, calls: calls).install(row: try row())
        XCTAssertEqual(loader.downloads, ["test.genome.fa", "test.annotation.gtf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.setURL.appendingPathComponent(ReferenceSetManifest.filename).path))
        XCTAssertEqual(calls.indexed, [outcome.setID])
        let kept = root.appendingPathComponent("rnaseq-reference-downloads/test-one", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path).sorted(), ["test.annotation.gtf", "test.genome.fa"])
        let manifest = try ReferenceSetManifest.load(from: outcome.setURL)
        XCTAssertEqual(manifest.genome.sha256, try row().genomeSHA256)
    }

    func testASecondInstallDownloadsNothingAndReusesTheSet() async throws {
        let loader = CopyingArchiveLoader()
        let first = try await installer(loader).install(row: try row())
        let second = try await installer(loader).install(row: try row())
        XCTAssertEqual(loader.downloads.count, 2)
        XCTAssertEqual(first.setID, second.setID)
    }

    func testAFileWhoseSha256DiffersIsDeletedAndNamedAndNoSetIsBuilt() async throws {
        let wrong = String(repeating: "0", count: 64)
        do {
            _ = try await installer(CopyingArchiveLoader()).install(row: try row(genomeSHA: wrong))
            XCTFail("a mismatched download was accepted")
        } catch let error as ReferenceSetInstallError {
            guard case .checksumMismatch(let file, let expected, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(file, "test.genome.fa")
            XCTAssertEqual(expected, wrong)
        }
        let kept = root.appendingPathComponent("rnaseq-reference-downloads/test-one", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path), [])
        let sets = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(ReferenceSetOwner.folderName).path)) ?? []
        XCTAssertEqual(sets.filter { !$0.hasPrefix(".") }, [])
    }

    func testAMacTooSmallForTheIndexIsRefusedBeforeAnyByteDownloads() async throws {
        let loader = CopyingArchiveLoader()
        do {
            _ = try await installer(loader, refuse: true).install(row: try row())
            XCTFail("the preflight did not refuse")
        } catch is RunFitError {}
        XCTAssertEqual(loader.downloads, [])
    }

    func testAnIdOutsideTheCatalogIsRefusedWithTheOfferedIds() async throws {
        do {
            _ = try await installer(CopyingArchiveLoader()).install("rhesus/ensembl-100")
            XCTFail("an id outside the catalog was installed")
        } catch let error as ReferenceSetInstallError {
            XCTAssertEqual(error, .notInCatalog("rhesus/ensembl-100", offered: ["human/gencode-50", "mouse/gencode-M39", "rhesus/ensembl-116", "cynomolgus/refseq-GCF_037993035.2"]))
        }
    }

    // MARK: - The catalog

    func testTheCatalogOffersHumanMouseRhesusAndCynomolgusEachAPinnedNamedDefault() {
        XCTAssertEqual(ReferenceSetCatalog.entries.map(\.id), ["human/gencode-50", "mouse/gencode-M39", "rhesus/ensembl-116", "cynomolgus/refseq-GCF_037993035.2"])
        for entry in ReferenceSetCatalog.entries {
            let row = entry.row
            XCTAssertEqual(row.genomeSHA256?.count, 64, entry.id)
            XCTAssertEqual(row.annotationSHA256?.count, 64, entry.id)
            XCTAssertTrue(row.genomeURL.hasPrefix("https://"), entry.id)
            XCTAssertGreaterThan(entry.downloadBytes, 800_000_000, entry.id)
        }
        XCTAssertEqual(ReferenceSetCatalog.entry("mouse/gencode-M39")?.row.species, "Mus musculus")
        // Each macaque entry is its species' default row (P5-REFS), so the catalog and `--default` agree.
        for id in ["rhesus/ensembl-116", "cynomolgus/refseq-GCF_037993035.2"] {
            XCTAssertEqual(ReferenceSetCatalog.entry(id)?.row.role.hasSuffix(" default"), true, id)
        }
        XCTAssertEqual(ReferenceSetCatalog.entries.map(\.title), [
            "Human, GRCh38 with GENCODE 50", "Mouse, GRCm39 with GENCODE M39",
            "Rhesus macaque, Mmul_10 with Ensembl 116", "Cynomolgus macaque, T2T-MFA8v1.1 with RefSeq",
        ])
    }

    func testTheStateReadsNotInstalledThenSetWithoutIndexThenReady() async throws {
        let testRow = try row()
        let entry = ReferenceSetCatalogEntry(id: "human/gencode-50", title: "x", downloadBytes: 1)
        XCTAssertEqual(ReferenceSetCatalog.state(of: entry, storageRoot: root), .notInstalled)
        // The state compares the row's pins, so a set of the test row is not the human entry's.
        let outcome = try await installer(CopyingArchiveLoader()).install(row: testRow)
        XCTAssertEqual(ReferenceSetCatalog.state(of: entry, storageRoot: root), .notInstalled)
        XCTAssertEqual(ReferenceSetCatalog.state(pins: testRow, storageRoot: root), .setWithoutIndex(setID: outcome.setID))
        let key = root.appendingPathComponent("rnaseq-index-cache/\(outcome.setID)/salmon-9.9.9-k31-genome-decoys", isDirectory: true)
        try FileManager.default.createDirectory(at: key.appendingPathComponent("index"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: key.appendingPathComponent("index/info.json"))
        XCTAssertEqual(ReferenceSetCatalog.state(pins: testRow, storageRoot: root), .setWithoutIndex(setID: outcome.setID))
        try Data("{}".utf8).write(to: key.appendingPathComponent("index-key.json"))
        XCTAssertEqual(ReferenceSetCatalog.state(pins: testRow, storageRoot: root), .ready(setID: outcome.setID))
        // A no-decoy index is not the one the quantify pane's defaults name.
        let other = root.appendingPathComponent("rnaseq-index-cache/\(outcome.setID)/salmon-9.9.9-k31-no-decoys", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(ReferenceSetCatalog.state(pins: testRow, storageRoot: root), .ready(setID: outcome.setID))
    }
}
