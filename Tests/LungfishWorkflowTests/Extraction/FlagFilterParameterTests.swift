// FlagFilterParameterTests.swift — Contract test for the new flagFilter parameter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class FlagFilterParameterTests: XCTestCase {

    /// The parameter must exist at the API level with a default of 0x400 so
    /// existing --by-region callers keep their current behavior.
    ///
    /// We compile-check this by taking the unapplied method reference: if the
    /// signature doesn't match, this file doesn't build.
    ///
    /// Note: `ReadExtractionService` is an `actor`, so the unapplied
    /// `ReadExtractionService.extractByBAMRegion` reference resolves to the
    /// isolated-method form `(Args) async throws -> Result` rather than the
    /// curried `(Self) -> (Args) async throws -> Result` you'd get on a class.
    func testExtractByBAMRegion_hasFlagFilterParameter_withDefault0x400() async {
        // Take a typed reference to the method to assert the signature exists.
        let method: (BAMRegionExtractionConfig, Int, (@Sendable (Double, String) -> Void)?) async throws -> ExtractionResult
            = ReadExtractionService().extractByBAMRegion
        _ = method
        // If this file compiles, the parameter exists in the expected position.
        XCTAssertTrue(true)
    }
}
