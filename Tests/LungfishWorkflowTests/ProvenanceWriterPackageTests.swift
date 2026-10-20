// ProvenanceWriterPackageTests.swift - The cleanup records keep their base bytes on the writer's package encode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.12, item 1 of `BIO-13.12.md`. Rows 5, 7 and 9 are the records of a cleanup that moves project
/// data to the Trash. Their readers check exact bytes and absolute paths (F5), so the encode keeps them as they were.
final class ProvenanceWriterPackageTests: XCTestCase {
    private typealias Fixtures = ProvenanceRecordFreezeFixtures

    func testPackagedCleanupRecordsKeepTheirBaseBytes() throws {
        try Fixtures.assertBytes(
            ProvenanceWriter.package(Fixtures.preparationEnvelope()),
            equalFixture: "cleanup-preparation-provenance.json"
        )
        try Fixtures.assertBytes(
            ProvenanceWriter.package(Fixtures.executionEnvelope()),
            equalFixture: "cleanup-execution-provenance.json"
        )
        try Fixtures.assertBytes(
            ProvenanceWriter.package(Fixtures.failureEnvelope()),
            equalFixture: "automatic-cleanup-failure-provenance.json"
        )
    }

    /// `package` writes no signature, so an envelope that names one would describe a pair that does not exist (BIO 4).
    func testPackageRefusesAnEnvelopeThatCarriesSignatures() throws {
        var envelope = Fixtures.executionEnvelope()
        envelope.signatures = [
            ProvenanceSignatureReference(
                provider: "local-ed25519",
                provenanceSHA256: Fixtures.digest,
                signaturePath: "provenance.json.signature.json"
            ),
        ]

        XCTAssertThrowsError(try ProvenanceWriter.package(envelope)) { error in
            XCTAssertEqual(error as? ProvenancePackageError, .envelopeCarriesSignatures(count: 1))
        }
    }
}
