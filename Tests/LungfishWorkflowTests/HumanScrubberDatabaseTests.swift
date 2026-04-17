// HumanScrubberDatabaseTests.swift - Tests for human scrubber database handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class HumanScrubberDatabaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("human-scrubber-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testHumanScrubberInstallerUsesPinnedManifestFilenameAndMd5URL() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("user-databases")
        )
        guard let manifest = await registry.manifest(for: "human-scrubber") else {
            XCTFail("Expected human-scrubber manifest")
            return
        }
        guard let artifactURLs = await registry.managedDatabaseArtifactURLs(for: manifest) else {
            XCTFail("Expected managed database URLs")
            return
        }

        XCTAssertEqual(artifactURLs.databaseURL.lastPathComponent, "human_filter.db.20250916v2")
        XCTAssertEqual(artifactURLs.databaseURL.absoluteString, "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20250916v2")
        XCTAssertEqual(artifactURLs.md5URL.lastPathComponent, "human_filter.db.20250916v2.md5")
        XCTAssertEqual(artifactURLs.md5URL.absoluteString, "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20250916v2.md5")
    }

    func testRequiredDatabasePathThrowsInstallRequiredWhenHumanScrubberDatabaseMissing() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "human-scrubber")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "human-scrubber")
            XCTAssertEqual(displayName, "Human Read Scrubber Database")
        }
    }

    func testRequiredDatabasePathMapsLegacyHumanScrubberIDToCanonicalManifest() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "sra-human-scrubber")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "human-scrubber")
            XCTAssertEqual(displayName, "Human Read Scrubber Database")
        }
    }

    func testRequiredDatabasePathMapsDeaconAliasToCanonicalManifest() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "deacon")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
        }
    }

    func testFASTQBatchImporterCanonicalizesLegacyHumanScrubberAliasToDeaconManagedDatabase() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )

        do {
            _ = try await FASTQBatchImporter.resolveHumanScrubberDatabasePath(
                databaseID: "sra-human-scrubber",
                registry: registry
            )
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
        }
    }

    func testFASTQBatchImporterReportsInstallRequiredWhenHumanScrubberDatabaseMissing() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("project"),
            recipe: ProcessingRecipe(
                name: "Human Scrub Only",
                steps: [
                    FASTQDerivativeOperation(
                        kind: .humanReadScrub,
                        createdAt: .distantPast,
                        humanScrubRemoveReads: true,
                        humanScrubDatabaseID: "human-scrubber"
                    )
                ]
            ),
            threads: 1
        )
        let pair = SamplePair(
            sampleName: "sample",
            r1: tempDir.appendingPathComponent("input_R1.fastq"),
            r2: tempDir.appendingPathComponent("input_R2.fastq")
        )
        try makeFASTQFile(at: pair.r1)
        try makeFASTQFile(at: try XCTUnwrap(pair.r2))

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            databaseRegistry: registry
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.errors.first?.error.contains("required before running human-read scrubbing") == true)
    }

    private func makeFASTQFile(at url: URL) throws {
        let content = """
        @read1
        ACGTACGTACGT
        +
        IIIIIIIIIIII
        @read2
        TGCATGCATGCA
        +
        IIIIIIIIIIII
        """
        try content.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func bundledDatabasesRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("bundled-databases", isDirectory: true)
        for databaseID in ["human-scrubber", "deacon-panhuman"] {
            let databaseDir = root.appendingPathComponent(databaseID, isDirectory: true)
            try FileManager.default.createDirectory(at: databaseDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try bundledManifestURL(for: databaseID),
                to: databaseDir.appendingPathComponent("manifest.json")
            )
        }
        return root
    }

    private func bundledManifestURL(for databaseID: String) throws -> URL {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/\(databaseID)/manifest.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("Bundled manifest not found at \(candidate.path)")
    }
}
