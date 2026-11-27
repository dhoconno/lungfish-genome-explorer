// RNASeqInstallReferenceCommandTests.swift - `lungfish-cli rnaseq install-reference` events and refusals (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqInstallReferenceCommandTests: XCTestCase {
    final class Lines: @unchecked Sendable {
        var all: [String] = []
    }

    private var savedRoot: String?

    override func setUp() {
        savedRoot = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
    }

    /// `--storage-root` sets `LUNGFISH_STORAGE_ROOT` in the process, as `rnaseq index` does.
    override func tearDown() {
        if let savedRoot { setenv("LUNGFISH_STORAGE_ROOT", savedRoot, 1) } else { unsetenv("LUNGFISH_STORAGE_ROOT") }
    }

    func events(_ lines: Lines) throws -> [[String: Any]] {
        try lines.all.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func testASetOutsideTheCatalogFailsInWordsAndExitsAsAnInputError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("install-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try RNASeqCommand.InstallReferenceSubcommand.parse(["--default", "rhesus/ensembl-100", "--storage-root", root.path])
        let lines = Lines()
        do {
            try await command.execute(eventsOn: true, quiet: true, emit: { lines.all.append($0) })
            XCTFail("an id outside the catalog was installed")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, CLIExitCode.inputError.exitCode)
        }
        let seen = try events(lines)
        XCTAssertEqual(seen.map { $0["event"] as? String }, ["failed"])
        XCTAssertEqual(seen.first?["error"] as? String,
                       "rhesus/ensembl-100 is not a reference set Lungfish installs. The sets are human/gencode-50, mouse/gencode-M39, "
                       + "rhesus/ensembl-116, cynomolgus/refseq-GCF_037993035.2.")
    }

    func testBuildIndexIsOffUnlessGiven() throws {
        XCTAssertFalse(try RNASeqCommand.InstallReferenceSubcommand.parse(["--default", "human/gencode-50"]).buildIndex)
        XCTAssertTrue(try RNASeqCommand.InstallReferenceSubcommand.parse(["--default", "human/gencode-50", "--build-index"]).buildIndex)
    }

    func testThreadsIsRefusedInWords() {
        XCTAssertThrowsError(try RNASeqCommand.InstallReferenceSubcommand.parse(["--default", "human/gencode-50", "--threads", "4"]))
    }

    func testARefusedPreflightEndsInOneFailedEventAfterStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("install-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try RNASeqCommand.InstallReferenceSubcommand.parse(["--default", "mouse/gencode-M39", "--storage-root", root.path])
        let install = ReferenceSetInstall(storageRoot: root, preflight: { _ in throw ReferenceSetInstallError.toolsMissing })
        let lines = Lines()
        do {
            try await command.execute(eventsOn: true, quiet: true, emit: { lines.all.append($0) }, install: install)
            XCTFail("a refused preflight installed a set")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, CLIExitCode.failure.exitCode)
        }
        let seen = try events(lines)
        XCTAssertEqual(seen.map { $0["event"] as? String }, ["start", "failed"])
        XCTAssertEqual(seen.last?["error"] as? String, ReferenceSetInstallError.toolsMissing.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rnaseq-reference-downloads").path))
    }
}
