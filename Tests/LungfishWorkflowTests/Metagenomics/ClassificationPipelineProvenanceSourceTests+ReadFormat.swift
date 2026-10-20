// ClassificationPipelineProvenanceSourceTests+ReadFormat.swift - Kraken2's read format in its pipeline record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.15, SW26 note 2 (BIO-13.15-SW26 items 3 and 5). The pipeline cannot tell a read format the user
/// chose from one a caller or the planner set, so its record files neither `pairedEnd` nor `readFormat` as explicit.
/// The resolved defaults hold the values the run used, and the format asked for when the run changed it.
extension ClassificationPipelineProvenanceSourceTests {
    func testAPlannedReadFormatIsNoExplicitOptionOfTheKraken2PipelineRecord() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(databaseDigest: nil)

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertNil(envelope.options.explicit["pairedEnd"])
        XCTAssertNil(envelope.options.explicit["readFormat"])
        XCTAssertEqual(envelope.options.resolvedDefaults["pairedEnd"], .boolean(false))
        XCTAssertEqual(envelope.options.resolvedDefaults["readFormat"], .string("unpaired"))
        XCTAssertNil(envelope.options.resolvedDefaults["requestedReadFormat"], "the run kept the format it was given")
    }

    /// An interleaved request over a file that is not strictly interleaved runs unpaired (the reconcile step before the
    /// mate split). The request is the resolved default `requestedReadFormat`.
    func testAnInterleavedKraken2RequestIsTheRequestedReadFormatResolvedDefault() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        var config = try fixture.makeConfig(databaseDigest: nil)
        config.interleavedInput = true
        XCTAssertEqual(config.readFormat, .interleaved)

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertNil(envelope.options.explicit["readFormat"])
        XCTAssertNil(envelope.options.explicit["pairedEnd"])
        XCTAssertEqual(envelope.options.resolvedDefaults["requestedReadFormat"], .string("interleaved"))
        XCTAssertEqual(envelope.options.resolvedDefaults["readFormat"], .string("unpaired"))
    }
}
