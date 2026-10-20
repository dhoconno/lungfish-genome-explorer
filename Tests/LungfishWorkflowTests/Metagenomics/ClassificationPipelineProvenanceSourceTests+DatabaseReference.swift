// ClassificationPipelineProvenanceSourceTests+DatabaseReference.swift - The Kraken2 database a run records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.15, DB-REF-SIZE with V2-1 (`votes/v2-BIO.md`). A run reads the database folder's install receipt
/// once, before it records anything. The registry's digest is recorded only when that receipt backs it, and then with
/// the size of the bytes it covers. A digest the receipt does not back is recorded as unpinned, with its reason, and
/// the run goes on.
extension ClassificationPipelineProvenanceSourceTests {
    /// The kraken2 step of the record a run of `config` saved, and the step's database reference input.
    private func kraken2Database(
        of config: ClassificationConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (step: ProvenanceStep, reference: ProvenanceFileDescriptor, completed: Bool) {
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory), file: file, line: line)
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" }, file: file, line: line)
        let reference = try XCTUnwrap(
            step.inputs.first { $0.path == config.databasePath.path && $0.role == .reference }, file: file, line: line
        )
        return (step, reference, envelope.status == .completed)
    }

    /// What a run whose registry digest no receipt backs records. No checksum, the size of the three core files, a
    /// null digest, the unpinned status and the note that keeps the registry's digest.
    private func assertUnpinned(
        _ config: ClassificationConfig,
        result: ClassificationResult,
        registryDigest: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorded = try kraken2Database(of: config, file: file, line: line)
        XCTAssertTrue(recorded.completed, "the run goes on", file: file, line: line)
        XCTAssertNil(recorded.reference.checksumSHA256, file: file, line: line)
        XCTAssertEqual(recorded.reference.fileSize, 24, "the three core files of 8 bytes", file: file, line: line)
        let resolved = recorded.step.resolvedOptions
        XCTAssertEqual(resolved["databaseDigest"], .null, file: file, line: line)
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("unresolved-bounded-metadata"), file: file, line: line)
        XCTAssertEqual(
            resolved["databaseIdentityNote"],
            .string(
                "The install receipt in \(config.databasePath.standardizedFileURL.path) does not back the registry's "
                    + "digest \(registryDigest), so this run records no digest."
            ),
            file: file, line: line
        )
        XCTAssertNil(result.config.databaseDigest, "classification-result.json records the same digest", file: file, line: line)
    }

    func testARegistryDigestWithNoReceiptIsRecordedAsUnpinnedWithItsReason() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let registryDigest = String(repeating: "ab", count: 32)
        let config = try fixture.makeConfig(databaseDigest: registryDigest)

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        try assertUnpinned(config, result: result, registryDigest: registryDigest)
    }

    func testARegistryDigestTheReceiptContradictsIsRecordedAsUnpinned() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let registryDigest = String(repeating: "ab", count: 32)
        let config = try fixture.makeConfig(databaseDigest: registryDigest)
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: config.databasePath)
        XCTAssertNotEqual(receipt.digest, registryDigest)

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        try assertUnpinned(config, result: result, registryDigest: registryDigest)
    }

    /// The folder holds the three core files and the other files its receipt lists. The digest and the size of the
    /// reference both cover every listed file, and the core sizes stay a resolved option of their own.
    func testACheckedDatabaseReferenceHasTheSizeItsDigestCovers() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let unchecked = try fixture.makeConfig(databaseDigest: nil)
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: unchecked.databasePath)
        let config = try fixture.makeConfig(databaseDigest: receipt.digest)
        XCTAssertNotNil(
            Kraken2DatabaseReceipt.verifiedReference(databasePath: config.databasePath, registryDigest: receipt.digest),
            "the fixture's folder keeps the bytes its receipt lists"
        )

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let recorded = try kraken2Database(of: config)
        XCTAssertEqual(recorded.reference.checksumSHA256, receipt.digest)
        XCTAssertEqual(recorded.reference.fileSize, receipt.size)
        XCTAssertGreaterThan(receipt.size, 24, "the receipt lists more than the three core files")
        let resolved = recorded.step.resolvedOptions
        XCTAssertEqual(resolved["databaseDigest"], .string(receipt.digest))
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("provided-aggregate-digest"))
        XCTAssertNil(resolved["databaseIdentityNote"])
        XCTAssertEqual(
            resolved["databaseCoreFileSizes"],
            .dictionary(["hash.k2d": .integer(8), "opts.k2d": .integer(8), "taxo.k2d": .integer(8)])
        )
        XCTAssertEqual(result.config.databaseDigest, receipt.digest)
    }
}
