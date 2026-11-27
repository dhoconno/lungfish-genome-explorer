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
        var adopted: [String] = []
        var preflights: [Bool] = []
        func note(_ id: String) { lock.withLock { indexed.append(id) } }
        func adopt(_ name: String) { lock.withLock { adopted.append(name) } }
        func preflight(_ served: Bool) { lock.withLock { preflights.append(served) } }
    }

    static let salmonBuild = "salmon-2.11.0-h0_0"

    func installer(_ loader: CopyingArchiveLoader, calls: Calls = Calls(), refuse: Bool = false) -> ReferenceSetInstall {
        let root = self.root!
        return ReferenceSetInstall(
            storageRoot: root, loader: loader,
            owner: ReferenceSetOwner(storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil)),
            indexer: { setID, _ in
                calls.note(setID)
                return root.appendingPathComponent("index-of-\(setID)")
            },
            adopter: { archive, served, _ in
                calls.adopt(archive.lastPathComponent)
                XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "the archive is downloaded before it is adopted")
                return root.appendingPathComponent("served-index-of-\(served.setID)")
            },
            salmonBuild: { Self.salmonBuild },
            preflight: { served in
                calls.preflight(served != nil)
                if refuse { throw RunFitError.insufficientMemory(needBytes: 2, haveBytes: 1, basis: "test", linuxRoute: "Use Linux") }
            })
    }

    /// A served index for `setID`, an archive of a few bytes in the server folder.
    func served(setID: String, salmonBuild: String = ReferenceSetInstallTests.salmonBuild) throws -> ServedSalmonIndex {
        let archive = sources.appendingPathComponent("served-index.zip")
        try Data("PK index".utf8).write(to: archive)
        return ServedSalmonIndex(
            url: archive.absoluteString, archiveBytes: archive.fileSizeBytes, archiveSHA256: try FileDigest.sha256(of: archive),
            unpackedBytes: 100, setID: setID, salmonBuild: salmonBuild, k: 31, decoys: .genome)
    }

    // MARK: - The served index

    /// Every catalog entry serves its index from the public LGE LabKey area (owner, 2026-11-27), built by the salmon
    /// the tools lock pins, so a Mac with the RNA-Seq pack takes the served path.
    func testEveryCatalogEntryServesAnIndexBuiltByTheLockedSalmonFromThePublicArea() throws {
        let lock = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json")
        let text = try String(contentsOf: lock, encoding: .utf8)
        let spec = try XCTUnwrap(text.range(of: #"bioconda::salmon=[0-9.]+=[A-Za-z0-9_]+"#, options: .regularExpression))
        let parts = text[spec].dropFirst("bioconda::".count).split(separator: "=")
        let locked = "salmon-\(parts[1])-\(parts[2])"
        for entry in ReferenceSetCatalog.entries {
            let served = try XCTUnwrap(entry.servedIndex, entry.id)
            XCTAssertEqual(served.salmonBuild, locked, entry.id)
            XCTAssertEqual(served.k, ReferenceSetCatalog.indexK, entry.id)
            XCTAssertEqual(served.decoys, ReferenceSetCatalog.indexDecoys, entry.id)
            let folder = "https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/databases/rnaseq-index/"
                + "\(served.setID)/salmon-\(parts[1])-k31-genome-decoys/"
            XCTAssertEqual(served.url, folder + "\(served.setID)-salmon-\(parts[1])-k31-genome-decoys.zip", entry.id)
            XCTAssertEqual(served.archiveSHA256.count, 64, entry.id)
            XCTAssertGreaterThan(served.unpackedBytes, served.archiveBytes, entry.id)
            XCTAssertLessThan(entry.memoryNeedBytes, 8_000_000_000, entry.id)
        }
        // The set ids name each species' assembly and annotation, as the set builder writes them.
        XCTAssertEqual(ReferenceSetCatalog.entries.compactMap { $0.servedIndex?.setID }, [
            "homo_sapiens-GRCh38-gencode50-lge-c287524e9a53", "mus_musculus-GRCm39-gencodem39-lge-398effa30daf",
            "macaca_mulatta-Mmul_10-ensembl116-lge-3f0fee25ce9e",
            "macaca_fascicularis-T2T-MFA8v1.1-refseqrs_2025_03-lge-b514efeeb33d",
        ])
    }

    func testAServedIndexForTheBuiltSetIsDownloadedAndAdoptedNotBuiltAndTheArchiveIsRemoved() async throws {
        let first = try await installer(CopyingArchiveLoader()).install(row: try row())
        let loader = CopyingArchiveLoader(), calls = Calls()
        let outcome = try await installer(loader, calls: calls).install(row: try row(), served: try served(setID: first.setID))
        XCTAssertEqual(calls.preflights, [true], "the check is the served need")
        XCTAssertEqual(calls.indexed, [], "no index is built")
        XCTAssertEqual(calls.adopted, ["served-index.zip"])
        XCTAssertEqual(loader.downloads, ["served-index.zip"], "the genome and GTF are kept from the first install")
        XCTAssertEqual(outcome.indexURL.lastPathComponent, "served-index-of-\(first.setID)")
        let kept = root.appendingPathComponent("rnaseq-reference-downloads/test-one", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept.path).sorted(), ["test.annotation.gtf", "test.genome.fa"])
    }

    /// A loader that copies a file URL and reports no total, as the LabKey server sends no Content-Length.
    final class NoLengthLoader: DemoProjectArchiveLoading, @unchecked Sendable {
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
            try FileManager.default.copyItem(at: url, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            progress(size / 2, nil)
            progress(size, nil)
        }
    }

    final class Steps: @unchecked Sendable {
        let lock = NSLock()
        var all: [ReferenceSetInstallProgress] = []
        func add(_ step: ReferenceSetInstallProgress) { lock.withLock { all.append(step) } }
    }

    /// With no Content-Length the served download's fraction comes from the row's archive bytes, not 0 of unknown.
    func testAServedDownloadWithNoLengthReportsItsFractionFromTheArchiveBytes() async throws {
        let first = try await installer(CopyingArchiveLoader()).install(row: try row())
        let steps = Steps()
        let root = self.root!
        let install = ReferenceSetInstall(
            storageRoot: root, loader: NoLengthLoader(),
            owner: ReferenceSetOwner(storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil)),
            indexer: { _, _ in XCTFail("no index is built"); return root },
            adopter: { _, _, _ in root }, salmonBuild: { Self.salmonBuild }, preflight: { _ in })
        let served = try served(setID: first.setID)
        _ = try await install.install(row: try row(), served: served) { steps.add($0) }
        let downloads = steps.all.compactMap { step -> (Double, String)? in
            if case .downloading(let fraction, let message) = step { return (fraction, message) }
            return nil
        }
        XCTAssertEqual(downloads.map(\.0), [0.5, 1.0])
        XCTAssertNil(downloads.last?.1.range(of: "unknown"), downloads.last?.1 ?? "")
    }

    func testAServedIndexForAnotherSetIdIsNotDownloadedAndTheIndexIsBuilt() async throws {
        let loader = CopyingArchiveLoader(), calls = Calls()
        let outcome = try await installer(loader, calls: calls).install(row: try row(), served: try served(setID: "testus-other-lge-000000000000"))
        XCTAssertEqual(calls.preflights, [true])
        XCTAssertEqual(calls.adopted, [])
        XCTAssertEqual(calls.indexed, [outcome.setID])
        XCTAssertEqual(loader.downloads, ["test.genome.fa", "test.annotation.gtf"])
    }

    func testAnotherSalmonBuildOrBuildIndexChecksTheBuildNeedAndBuildsTheIndex() async throws {
        for (build, force) in [("salmon-9.9.9-h0_0", false), (Self.salmonBuild, true)] {
            let first = try await installer(CopyingArchiveLoader()).install(row: try row())
            let loader = CopyingArchiveLoader(), calls = Calls()
            _ = try await installer(loader, calls: calls)
                .install(row: try row(), served: try served(setID: first.setID, salmonBuild: build), buildIndex: force)
            XCTAssertEqual(calls.preflights, [false], build)
            XCTAssertEqual(calls.adopted, [], build)
            XCTAssertEqual(calls.indexed, [first.setID], build)
            XCTAssertEqual(loader.downloads, [], build)
        }
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
