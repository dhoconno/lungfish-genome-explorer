// GenotypeAIHaplotypingCommandRecordTests.swift - The AI Haplotyping row, its record and its key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.19 (L11, BIO 4, Q-S10). Each test runs
// `GenotypeAIHaplotypingExecutionService.run` end to end on
// `GenotypeAIHaplotypingRunFixture`, whose provider is a loopback stand-in
// with a recorded reply and whose key is a throwaway on a stand-in keychain
// service. The CLI's own lookup order (environment, then keychain, with the
// Azure key first under Azure settings) is pinned in GenotypeSubcommandsTests.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class GenotypeAIHaplotypingCommandRecordTests: XCTestCase {
    func testDiscoveryRowRecordsNoCommandAndTheRevisionRecordsThePreview() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let published = try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(fixture.operationCenter.items.count, 1)
        XCTAssertEqual(item.title, "AI Haplotyping")
        XCTAssertEqual(item.state, .completed)
        // Today the row records no command (cli-parity-gap: ai-haplotyping).
        XCTAssertNil(item.cliCommand)

        let argv = try await fixture.expectedArgv()
        let preview = ViralReconWorkflowCommandPreview.build(
            executableName: argv[0],
            arguments: Array(argv.dropFirst())
        )
        XCTAssertTrue(item.logEntries.map(\.message).contains(preview), "\(item.logEntries.map(\.message))")
        // The record names the preview for the run and for its one step. Its
        // other argv is the copy of the specialist prompt into the revision.
        let recordArgvs = try GenotypeAIHaplotypingRunFixture.argvArrays(inRecordAt: published.provenanceURL)
        XCTAssertEqual(recordArgvs.filter { $0.first == CLICommandIdentity.executableName }, [argv, argv])
        XCTAssertEqual(fixture.server.requests.map(\.path), ["/openai/v1/responses"])
    }

    func testMissingKeyFailsTheRowAfterItBegins() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self, storesKey: false)
        do {
            try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)
            XCTFail("A run with no key must throw")
        } catch let error as AIProviderError {
            guard case .missingAPIKey = error else { return XCTFail("\(error)") }
        }

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(fixture.operationCenter.items.count, 1)
        XCTAssertEqual(item.state, .failed)
        XCTAssertNil(item.cliCommand)
        XCTAssertEqual(item.errorMessage, "AI haplotyping failed")
        XCTAssertEqual(item.errorDetail, AIProviderError.missingAPIKey.errorDescription)
        XCTAssertEqual(fixture.server.requests.count, 0)
    }

    func testThrowawayKeyReachesOnlyTheProviderRequestHeader() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)

        let key = fixture.throwawayKey
        XCTAssertFalse(fixture.rowTexts().contains { $0.contains(key) }, "the key reached the row or its log")
        XCTAssertEqual(try fixture.filesContaining(key), [], "the key reached a record")
        let request = try XCTUnwrap(fixture.server.requests.first)
        XCTAssertEqual(request.headerLines.filter { $0.contains(key) }, ["api-key: \(key)"])
        XCTAssertFalse(request.target.contains(key))
        XCTAssertNil(request.body.range(of: Data(key.utf8)))
    }

    func testRefusedProviderRequestShowsNoKeyInTheFailureSheet() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self, providerStatus: 400)
        do {
            try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)
            XCTFail("A refused provider request must fail the run")
        } catch {}

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "AI haplotyping failed")
        XCTAssertFalse(item.errorDetail?.isEmpty ?? true)
        let key = fixture.throwawayKey
        XCTAssertFalse(fixture.rowTexts().contains { $0.contains(key) }, "the key reached the failure sheet")
        XCTAssertEqual(try fixture.filesContaining(key), [], "the key reached a file")
    }
}
