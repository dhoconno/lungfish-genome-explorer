// FlagFilterParameterTests.swift — Contract test for the new flagFilter parameter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class FlagFilterParameterTests: XCTestCase {

    /// Pins that `extractByBAMRegion` has an `Int` parameter in the second
    /// position (between `config` and `progress`) via a compile-time typed
    /// method-reference assignment. If someone renames, reorders, or retypes
    /// the parameter, this file fails to build.
    ///
    /// This test does NOT verify the parameter's default value — taking a
    /// method reference erases default values. The default-argument contract
    /// (currently `0x400`) is exercised by Phase 2's resolver tests, which
    /// will drive the actual `samtools` argument vector through a fake
    /// `NativeToolRunner`.
    ///
    /// Note: `ReadExtractionService` is an `actor`, so the unapplied
    /// `ReadExtractionService.extractByBAMRegion` reference resolves to the
    /// isolated-method form `(Args) async throws -> Result` rather than the
    /// curried `(Self) -> (Args) async throws -> Result` you'd get on a class.
    /// That forces us to bind against an instance — the throwaway
    /// `ReadExtractionService()` allocation below is purely a workaround for
    /// that constraint; the test cares about the type, not the instance.
    func testExtractByBAMRegion_hasFlagFilterIntParameterInSecondPosition() {
        // Take a typed reference to the method to assert the signature exists.
        let method: (BAMRegionExtractionConfig, Int, (@Sendable (Double, String) -> Void)?) async throws -> ExtractionResult
            = ReadExtractionService().extractByBAMRegion
        _ = method
        // If this file compiles, the parameter exists in the expected position.
    }
}
