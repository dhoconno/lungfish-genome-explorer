// DatabaseUpdateReplaceOrderPinTests.swift - The order of an in-place database update's writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M1 (family L10, plan decision C10, SWIFT and QA). The Plugin Manager's
// database update will run `conda db update` under the app's cancel, so the way the update
// replaces the installed database folder is pinned first, from a stand-in archive installer
// because the real one downloads gigabytes. The folder is replaced in this order. The new copy is
// staged in a sibling folder, verified, given its receipt there, and only then swapped in by two
// renames before the registry row is saved. A cancel or a failure at any step before the swap
// leaves the installed copy exactly as it was and leaves no residue, and a failed save puts the
// previous copy back. The suite changes no source and passes at the base.

import XCTest
import CryptoKit
@testable import LungfishWorkflow
import LungfishTestSupport

final class DatabaseUpdateReplaceOrderPinTests: XCTestCase {
    private var base: URL!
    private var kraken2: URL!
    private var installed: URL!

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-replace-order-\(UUID().uuidString)", isDirectory: true)
        kraken2 = base.appendingPathComponent("kraken2", isDirectory: true)
        installed = kraken2.appendingPathComponent("viral", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try await super.tearDown()
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        var shouldFail: Bool { lock.withLock { enabled } }
        func enable() { lock.withLock { enabled = true } }
    }

    private static let payloadFiles = ["hash.k2d", "opts.k2d", "taxo.k2d"]

    private static func writePayload(at directory: URL, marker: String) throws {
        for name in payloadFiles {
            try marker.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// The marker of every payload file in `directory`, "missing" for a file that is not there.
    private static func markers(of directory: URL) -> [String] {
        payloadFiles.map {
            (try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) ?? "missing"
        }
    }

    private func siblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: kraken2.path).sorted()
    }

    /// A registry holding one installed Viral database whose three files read "old".
    private func makeRegistry(
        manifestWriter: @escaping @Sendable (Data, URL) throws -> Void = MetagenomicsDatabaseRegistry.defaultManifestWriter
    ) async throws -> MetagenomicsDatabaseRegistry {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base, manifestWriter: manifestWriter)
        try await registry.loadIfNeeded()
        try Self.writePayload(at: installed, marker: "old")
        let adopted = try await registry.seedRowThroughManifest(at: installed, name: "Viral")
        // The folder was adopted without a receipt, so its row records no version. The tests below compare the
        // version before and after a failed or cancelled update and rely on a missing version staying missing.
        XCTAssertNil(adopted.version, "an adopted folder records no version")
        return registry
    }

    private func assertInstalledCopyIsWhole(
        _ registry: MetagenomicsDatabaseRegistry, versionBefore: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(Self.markers(of: installed), ["old", "old", "old"], file: file, line: line)
        XCTAssertEqual(try siblings(), ["viral"], "no staged or retired copy is left", file: file, line: line)
        let row = try await registry.database(named: "Viral")
        XCTAssertEqual(row?.version, versionBefore, file: file, line: line)
        XCTAssertEqual(row?.status, .ready, file: file, line: line)
    }

    func testTheNewCopyIsStagedBesideTheInstalledOneVerifiedAndReceiptedBeforeTheSwap() async throws {
        let registry = try await makeRegistry()
        let observations = Observations()
        let kraken2 = self.kraken2!
        let installed = self.installed!

        await registry.setArchiveInstallerForTesting { _, destination, _ in
            observations.add(
                "download installed=\(Self.markers(of: installed)) stagingExists=\(FileManager.default.fileExists(atPath: destination.path))"
                    + " sibling=\(destination.deletingLastPathComponent().standardizedFileURL == kraken2.standardizedFileURL)"
            )
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writePayload(at: destination, marker: "new")
            return nil
        }
        await registry.setExpectedChecksumForTesting { _ in
            let staged = ((try? FileManager.default.contentsOfDirectory(atPath: kraken2.path)) ?? [])
                .filter { $0 != "viral" }
            let stagedURL = staged.first.map { kraken2.appendingPathComponent($0, isDirectory: true) }
            let receipt = stagedURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(ProvenanceWriter.provenanceFilename).path)
            } ?? false
            observations.add(
                "verify installed=\(Self.markers(of: installed)) staged=\(stagedURL.map(Self.markers(of:)) ?? []) receipt=\(receipt)"
            )
            return nil
        }

        try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }

        XCTAssertEqual(observations.all, [
            "download installed=[\"old\", \"old\", \"old\"] stagingExists=false sibling=true",
            "verify installed=[\"old\", \"old\", \"old\"] staged=[\"new\", \"new\", \"new\"] receipt=false",
        ], "the installed copy is untouched while the new one is staged, and the receipt comes after the verification")

        XCTAssertEqual(Self.markers(of: installed), ["new", "new", "new"])
        XCTAssertEqual(try siblings(), ["viral"], "the swap leaves no staged or retired copy")
        let stored = try await registry.database(named: "Viral")
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.version, ManagedToolLock.bundled.database(id: "kraken2-viral")?.version)

        // The receipt was written into the staged copy and travelled with it. The row's digest of
        // the receipt is the digest of the file the swap put in place, so nothing wrote it after.
        let receipt = installed.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let digest = SHA256.hash(data: try Data(contentsOf: receipt)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(row.canonicalReceiptSHA256, digest)

        // The row was saved after the swap, so a registry that reads the file sees the new version.
        let reloaded = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await reloaded.loadIfNeeded()
        let reloadedRow = try await reloaded.database(named: "Viral")
        XCTAssertEqual(reloadedRow?.version, row.version)
    }

    func testACancelledDownloadLeavesTheInstalledCopyWholeAndNoResidue() async throws {
        let registry = try await makeRegistry()
        let versionBefore = try await registry.database(named: "Viral")?.version
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "partial".write(to: destination.appendingPathComponent("hash.k2d"), atomically: true, encoding: .utf8)
            throw CancellationError()
        }

        do {
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
            XCTFail("a cancelled download must not finish the update")
        } catch is CancellationError {
        }

        try await assertInstalledCopyIsWhole(registry, versionBefore: versionBefore)
    }

    func testACancelOnceTheDownloadEndsLeavesTheInstalledCopyWholeAndNoResidue() async throws {
        let registry = try await makeRegistry()
        let versionBefore = try await registry.database(named: "Viral")?.version
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writePayload(at: destination, marker: "new")
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }

        do {
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
            XCTFail("a cancel after the download must stop the update before the swap")
        } catch is CancellationError {
        }

        try await assertInstalledCopyIsWhole(registry, versionBefore: versionBefore)
    }

    func testACancelAfterTheReceiptIsWrittenDiscardsTheStagedCopy() async throws {
        let registry = try await makeRegistry()
        let versionBefore = try await registry.database(named: "Viral")?.version
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writePayload(at: destination, marker: "new")
            return nil
        }
        // The verification step runs before the receipt is written, and the last cancel check
        // sits after it, so a cancel here is seen once the staged copy holds its receipt.
        await registry.setExpectedChecksumForTesting { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }

        do {
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
            XCTFail("a cancel before the swap must stop the update")
        } catch is CancellationError {
        }

        try await assertInstalledCopyIsWhole(registry, versionBefore: versionBefore)
    }

    func testAFailedSaveAfterTheSwapPutsThePreviousCopyBack() async throws {
        let failure = FailureSwitch()
        let registry = try await makeRegistry { data, url in
            if failure.shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            try MetagenomicsDatabaseRegistry.defaultManifestWriter(data, url)
        }
        let versionBefore = try await registry.database(named: "Viral")?.version
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writePayload(at: destination, marker: "new")
            return nil
        }
        failure.enable()

        do {
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
            XCTFail("an update whose row cannot be saved must fail")
        } catch is CancellationError {
            XCTFail("a failed save is not a cancel")
        } catch {
        }

        try await assertInstalledCopyIsWhole(registry, versionBefore: versionBefore)
    }
}
