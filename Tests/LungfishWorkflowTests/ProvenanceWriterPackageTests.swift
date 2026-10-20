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
            ProvenanceJSON.encoder.encode(Fixtures.preparationEnvelope()),
            equalFixture: "cleanup-preparation-provenance.json"
        )
        try Fixtures.assertBytes(
            ProvenanceJSON.encoder.encode(Fixtures.executionEnvelope()),
            equalFixture: "cleanup-execution-provenance.json"
        )
        try Fixtures.assertBytes(
            ProvenanceJSON.encoder.encode(Fixtures.failureEnvelope()),
            equalFixture: "automatic-cleanup-failure-provenance.json"
        )
    }
}
