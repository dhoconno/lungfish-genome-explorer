// SRABatchLookupTests.swift - Tests for batch ENA lookup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRABatchLookupTests: XCTestCase {

    func testBatchLookupMethodExists() async throws {
        let service = ENAService()
        let results = try await service.searchReadsBatch(
            accessions: [],
            concurrency: 5,
            progress: { _, _ in }
        )
        XCTAssertTrue(results.isEmpty)
    }
}
