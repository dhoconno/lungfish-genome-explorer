// ImportFastqRecordTruthTests.swift - A real import's record states what the command ran (CHTC lane L5-RECORDS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import CryptoKit
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Each test runs `lungfish-cli import fastq` on the sarscov2 pair and reads the bundle it writes, so the assertions
/// read the record a user would replay, never the source that builds it.
final class ImportFastqRecordTruthTests: XCTestCase {

    private var cliBinaryPath: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
    }

    private var fixturesDir: URL? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Imports the sarscov2 pair with `arguments` after the inputs and project, and returns the bundle's record and
    /// its sidecar metadata.
    private func importFixturePair(
        _ arguments: [String]
    ) throws -> (envelope: ProvenanceEnvelope, metadata: PersistedFASTQMetadata?) {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }
        guard let binary = cliBinaryPath else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("record-truth-\(UUID().uuidString)")
        let input = root.appendingPathComponent("input")
        let project = root.appendingPathComponent("p.lungfish")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: input.appendingPathComponent(name)
            )
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["import", "fastq", input.path, "--project", project.path] + arguments
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "import fastq failed: \(stderr)")

        let bundle = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: project.appendingPathComponent("Imports"), includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lungfishfastq" },
            "the import wrote no bundle"
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let payload = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        return (envelope, payload.flatMap { FASTQMetadataStore.load(for: $0) })
    }

    // MARK: - M1, true recorded defaults

    /// A recipe whose file suggests `illumina4` binning, run with neither `--quality-binning` nor `--threads`, runs
    /// `none` on every core. The record names those as the defaults, not the recipe's suggestion and not 4 threads.
    func testRecordedDefaultsAreTheValuesTheCommandRanWithout() throws {
        let (envelope, metadata) = try importFixturePair([
            "--platform", "illumina",
            "--recipe", "illumina-amplicon-merge",
            "--no-optimize-storage",
            "--compression", "fast",
        ])
        let cores = ProcessInfo.processInfo.activeProcessorCount

        XCTAssertEqual(metadata?.ingestion?.qualityBinning, QualityBinningScheme.none.rawValue,
                       "the import ran without binning")
        XCTAssertEqual(envelope.options.explicit["qualityBinning"], .string(QualityBinningScheme.none.rawValue))
        XCTAssertEqual(envelope.options.defaults["qualityBinning"], .string(QualityBinningScheme.none.rawValue),
                       "the recorded default must be the binning the command runs when the option is absent")
        XCTAssertEqual(envelope.options.explicit["threads"], .integer(cores))
        XCTAssertEqual(envelope.options.defaults["threads"], .integer(cores),
                       "the recorded default must be the thread count the command runs when the option is absent")
    }

    // MARK: - M2, recipe identity

    /// The record names the recipe file that ran by the SHA-256 of its bytes and its format version, beside the id
    /// and name, so a plan built elsewhere can prove it ran the same file.
    func testRecordNamesTheRecipeFileThatRanByItsDigest() throws {
        let (envelope, metadata) = try importFixturePair([
            "--platform", "illumina",
            "--recipe", "illumina-amplicon-merge",
            "--no-optimize-storage",
            "--compression", "fast",
        ])
        let recipeFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Recipes/illumina-amplicon-merge.recipe.json")
        let expected = SHA256.hash(data: try Data(contentsOf: recipeFile)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeID, "illumina-amplicon-merge")
        XCTAssertEqual(envelope.options.resolvedDefaults["recipeSHA256"], .string(expected),
                       "the record must name the recipe file's bytes")
        XCTAssertEqual(envelope.options.resolvedDefaults["recipeFormatVersion"], .integer(1))
        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeSHA256, expected, "the sidecar must name it too")
        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeFormatVersion, 1)
    }
}
