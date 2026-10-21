// ManagedToolLeavesLiveConformanceTests.swift - SIGTERM cancels a real database download on the built CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Phase 2.10 lane A52 M2 (family L10, panel decisions C10 and G1), under the QA ruling on 2.9
/// owner direction O5. The built `lungfish-cli` has no stand-in for the archive download of
/// `conda db update`, since the catalog holds the archive's address, so the check of the third leaf
/// is the live form. It downloads the real Viral archive for a few seconds, sends SIGTERM to the CLI
/// and asserts that it exits 125, records the run as cancelled, leaves no process and leaves the
/// installed database exactly as it was with no staged copy beside it.
///
/// It runs its body only when LUNGFISH_REQUIRE_TOOLS=1 is set and the built CLI is found. Its name
/// ends in LiveConformanceTests, so only the conformance tier selects it. The in-process cancel in
/// `ManagedToolLeavesTests` stays the default and the fallback.
final class ManagedToolLeavesLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard ToolAvailability.requireTools else {
            throw XCTSkip("Set LUNGFISH_REQUIRE_TOOLS=1 to cancel a real database download on the built lungfish-cli")
        }
        guard CLISIGTERMHarness.cliBinaryURL(for: Self.self) != nil else {
            try ToolAvailability.skipOrFail("no lungfish-cli is built beside the test bundle")
        }
        root = try TestTempDirectory.make(prefix: "managed-tool-live")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    private static let payloadFiles = ["hash.k2d", "opts.k2d", "taxo.k2d"]

    private static func markers(of directory: URL) -> [String] {
        payloadFiles.map {
            (try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) ?? "missing"
        }
    }

    func testSIGTERMCancelsARealDatabaseDownloadLeavingTheInstalledCopyWhole() async throws {
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let databases = storageRoot.appendingPathComponent("databases", isDirectory: true)
        let kraken2 = databases.appendingPathComponent("kraken2", isDirectory: true)
        let installed = kraken2.appendingPathComponent("viral", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for name in Self.payloadFiles {
            try "old".write(to: installed.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: databases)
        let before = try await registry.seedRowThroughManifest(at: installed, name: "Viral")
        // The folder was adopted without a receipt, so its row records no version. The equality on `version` at the
        // end then fails if the cancelled update wrote any version at all.
        XCTAssertNil(before.version, "an adopted folder records no version")

        let cli = try CLISIGTERMHarness.launchCLI(
            ["conda", "db", "update", "kraken2-viral", "--yes", "--format", "json"],
            environment: [
                "LUNGFISH_STORAGE_ROOT": storageRoot.path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }

        // The staged copy appears beside the installed one when the download starts. A moment later
        // the archive is coming in.
        let staging = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            ((try? FileManager.default.contentsOfDirectory(atPath: kraken2.path)) ?? []).contains { $0 != "viral" }
        }
        guard staging else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never began the download.\(stop.diagnostics)")
        }
        try await Task.sleep(for: .seconds(2))

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try ManagedToolLeafFixtures.recordStatus(storageRoot: storageRoot, folder: "databases")
        }

        XCTAssertEqual(Self.markers(of: installed), ["old", "old", "old"], "the installed database is whole")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: kraken2.path).sorted(), ["viral"],
            "no staged or retired copy is left. \(stop.diagnostics)"
        )
        let after = try await MetagenomicsDatabaseRegistry(baseDirectory: databases).database(named: "Viral")
        XCTAssertEqual(after?.version, before.version)
        XCTAssertEqual(after?.status, .ready)
    }
}
