// TaxTriagePlatformSourceTests.swift - What SW13 changes in the platform a TaxTriage record files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.15 M1 (SW13, MD34, BIO 4). A platform that a bundle recorded, or that the run took because the
// user named none, is a resolved default of the record and the record names where it came from. A platform the user
// typed stays an explicit option (`TaxTriagePlatformPinTests`). The source is no setting of the run, so the persisted
// configuration does not change.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriagePlatformSourceTests: TaxTriagePlatformTestCase {

    func testABundlesPlatformIsAResolvedDefaultThatNamesItsBundle() async throws {
        let config = try await plannedConfig(of: try makeBundle("ont", platform: .oxfordNanopore), typed: false)

        XCTAssertEqual(config.platform, .oxford)
        assertFiledAsResolved(config, platform: "OXFORD", source: "bundle")
    }

    func testAPlatformTheUserNamedNoneForIsAResolvedDefaultThatNamesTheDefault() async throws {
        let config = try await plannedConfig(of: try makeLooseReads("loose"), typed: false)

        XCTAssertEqual(config.platform, .illumina)
        assertFiledAsResolved(config, platform: "ILLUMINA", source: "default")
    }

    /// A bundle runs on its own platform whatever `--platform` says, so the record names the bundle and not the flag.
    func testABundlesPlatformWinsOverATypedPlatformAndTheRecordNamesTheBundle() async throws {
        let config = try await plannedConfig(of: try makeBundle("ont", platform: .oxfordNanopore), platform: .pacbio, typed: true)

        XCTAssertEqual(config.platform, .oxford)
        assertFiledAsResolved(config, platform: "OXFORD", source: "bundle")
    }

    /// MD34. The source is outside the coding keys, so a configuration that names one encodes to the bytes of one
    /// that does not, and a saved configuration reads back with no source.
    func testTheSourceOfThePlatformIsNoPartOfTheEncodedConfiguration() async throws {
        let config = try await plannedConfig(of: try makeBundle("ont", platform: .oxfordNanopore), typed: false)
        XCTAssertEqual(TaxTriageRecordFacts(config: config).resolvedDefaults["platformSource"], .string("bundle"), "the plan set a source")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(config)
        let reread = try JSONDecoder().decode(TaxTriageConfig.self, from: encoded)

        XCTAssertNil(TaxTriageRecordFacts(config: reread).resolvedDefaults["platformSource"], "a saved configuration names no source")
        XCTAssertEqual(try encoder.encode(reread), encoded, "the same bytes with the source and without it")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("platformSource"))
    }

    private func assertFiledAsResolved(
        _ config: TaxTriageConfig,
        platform: String,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let facts = TaxTriageRecordFacts(config: config)
        XCTAssertNil(facts.explicitOptions["platform"], file: file, line: line)
        XCTAssertEqual(facts.resolvedDefaults["platform"], .string(platform), file: file, line: line)
        XCTAssertEqual(facts.resolvedDefaults["platformSource"], .string(source), file: file, line: line)
        let rootOptions = TaxTriageRecordFacts.rootRecordOptions(fromRunParameters: facts.runParameters)
        XCTAssertNil(rootOptions.explicit["platform"], file: file, line: line)
        XCTAssertEqual(rootOptions.resolved["platform"], .string(platform), file: file, line: line)
        XCTAssertEqual(rootOptions.resolved["platformSource"], .string(source), file: file, line: line)
        let saved = TaxTriageRecordFacts.recordOptions(fromRunParameters: facts.runParameters)
        XCTAssertEqual(saved.resolvedDefaults["platform"], .string(platform), file: file, line: line)
        XCTAssertEqual(saved.resolvedDefaults["platformSource"], .string(source), file: file, line: line)
    }
}
