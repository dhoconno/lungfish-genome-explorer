// BlastStandInRootTests.swift - A stand-in run keeps its shared BLAST files away from the real root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE item 21 and section 7). `LUNGFISH_BLAST_STAND_IN_STATE` takes
/// the place of `<root>/blast/`, so two children can share one ledger. The child gets its own home through
/// `CFFIXED_USER_HOME`, so its default root sits under this test's scratch folder, and no test exports
/// `LUNGFISH_STORAGE_ROOT`.
final class BlastStandInRootTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-standin-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testStandInStateNeverReachesTheRoot() async throws {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        let server = try BlastSubmitStandInTests.standIn()
        defer { server.stop() }
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let state = scratch.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let query = scratch.appendingPathComponent("query.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        let output = scratch.appendingPathComponent("result", isDirectory: true)

        let result = try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli,
            arguments: [
                "blast", "submit", "--query", query.path, "--output", output.path, "--name", "Influenza A virus",
                "--taxid", "11320", "--source-result", scratch.path, "--sample", "S1", "--subsample-count", "2",
                "--format", "json",
            ],
            environment: CLISIGTERMHarness.childEnvironment(overriding: [
                "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
                "LUNGFISH_BLAST_STAND_IN_STATE": state.path,
                "CFFIXED_USER_HOME": home.path,
            ]),
            timeout: .seconds(90)
        ))
        XCTAssertEqual(result.status, 0, result.stderrText)

        let ledger = FileBlastSubmissionLedger(fileURL: state.appendingPathComponent(FileBlastSubmissionLedger.fileName))
        let counted = await ledger.events(at: Date()).map(\.count)
        XCTAssertEqual(counted, [2], "the two reads the child sent are counted in the state folder")

        let underHome = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(underHome.contains(FileBlastSubmissionLedger.fileName), "no ledger under the child's root")
        XCTAssertFalse(underHome.contains(FileBlastSubmissionLedger.directoryName), "no blast folder under the child's root")
    }
}
