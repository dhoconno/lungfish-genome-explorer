// SalmonIndexAdoptTests.swift - A served salmon index adopted into the cache (2026-11-27)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `docs/plans/2026-11-27-rnaseq-served-salmon-index.md`: the archive holds `index/` and `index-key.json` only, and the
// cache writes its own record, so no path of the Mac that built it is served.

import LungfishCore
import XCTest
@testable import LungfishWorkflow

extension SalmonIndexCacheTests {
    /// Builds the index of a new set with the stand-in, zips its `index/` and `index-key.json` with `extra` entries, and
    /// removes the published folder, so the archive is what a served row names.
    func servedArchive(extra: [String] = []) async throws -> (archive: URL, served: ServedSalmonIndex, set: ReferenceSetOutcome) {
        let set = try await makeSet()
        let built = try await ensure(SalmonIndexRequest(setID: set.manifest.id))
        for name in extra {
            let url = built.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        let file = try JSONDecoder().decode(
            SalmonIndexKeyFile.self, from: Data(contentsOf: built.url.appendingPathComponent(SalmonIndexKeyFile.filename)))
        let archive = base.appendingPathComponent("served.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = built.url
        zip.arguments = ["-q", "-r", "-X", archive.path, "index", SalmonIndexKeyFile.filename] + extra
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        try FileManager.default.removeItem(at: built.url)
        let served = ServedSalmonIndex(
            url: archive.absoluteString, archiveBytes: archive.fileSizeBytes, archiveSHA256: try FileDigest.sha256(of: archive),
            unpackedBytes: 1_000, setID: set.manifest.id, salmonBuild: file.salmonBuild, k: file.k, decoys: file.decoys)
        return (archive, served, set)
    }

    func adopt(_ archive: URL, _ served: ServedSalmonIndex) async throws -> SalmonIndexOutcome {
        try await cache().adopt(archive: archive, served: served, argv: ["lungfish-cli", "rnaseq", "install-reference"])
    }

    func testAServedArchiveIsAdoptedWithItsOwnRecordAndNoSalmonRuns() async throws {
        let (archive, served, set) = try await servedArchive()
        let runs = indexRuns()
        let outcome = try await adopt(archive, served)
        XCTAssertEqual(indexRuns(), runs, "adopting starts no salmon index")
        XCTAssertFalse(outcome.reused)
        XCTAssertEqual(outcome.hashes.all, Self.builtHashes)
        let key = SalmonIndexKey(setID: set.manifest.id, salmonVersion: "2.11.0", k: 31, decoys: .genome)
        XCTAssertEqual(try cache().published(key)?.url, outcome.url)
        XCTAssertEqual(try entries(outcome.url), [".lungfish-provenance.json", "index", "index-key.json", "provenance", "uses"])
        let record = try String(contentsOf: outcome.url.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertNotNil(record.range(of: "RNA-seq salmon index, served"), record)
        XCTAssertNotNil(record.range(of: served.archiveSHA256), "the record names the archive it came from")
        XCTAssertNotNil(record.range(of: outcome.url.appendingPathComponent("index/refseq.bin").path), "outputs name this Mac's paths")
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [outcome.url.lastPathComponent], "no stage is left")
    }

    func testAnArchiveWhoseSha256DiffersPublishesNothing() async throws {
        var (archive, served, set) = try await servedArchive()
        served.archiveSHA256 = String(repeating: "0", count: 64)
        do {
            _ = try await adopt(archive, served)
            XCTFail("an archive with another sha256 was adopted")
        } catch let error as SalmonIndexError {
            guard case .servedIndexDiffers(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertNotNil(reason.range(of: "sha256"), reason)
        }
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [])
    }

    func testAnArchiveWithAnythingButTheIndexAndItsKeyPublishesNothing() async throws {
        let (archive, served, set) = try await servedArchive(extra: ["uses/someone.json"])
        do {
            _ = try await adopt(archive, served)
            XCTFail("an archive holding uses/ was adopted")
        } catch let error as SalmonIndexError {
            XCTAssertEqual(error, .servedIndexDiffers("The archive holds uses/someone.json, which a served index never holds."))
        }
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [])
    }

    func testAnArchiveForAnotherSetOrSalmonBuildIsRefusedBeforeItIsRead() async throws {
        var (archive, served, set) = try await servedArchive()
        let local = served.salmonBuild
        served.salmonBuild = "salmon-9.9.9-h0_0"
        do {
            _ = try await adopt(archive, served)
            XCTFail("an index of another salmon build was adopted")
        } catch let error as SalmonIndexError {
            // These are the words of the check before the archive is read, not of the key file's check after it.
            XCTAssertEqual(error, .servedIndexDiffers(
                "The served index was built by salmon-9.9.9-h0_0, and this Mac's salmon is \(local)."))
        }
        XCTAssertEqual(try entries(setFolder(set.manifest.id)), [])
    }
}
