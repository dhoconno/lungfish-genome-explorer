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
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class GenotypeAIHaplotypingCommandRecordTests: XCTestCase {
    func testDiscoveryRowRecordsTheResolvedCommandAndTheRevisionRecordsTheSameArgv() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let published = try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(fixture.operationCenter.items.count, 1)
        XCTAssertEqual(item.title, "AI Haplotyping")
        XCTAssertEqual(item.state, .completed)

        // The row records the command it was begun with, naming the provider
        // and model the run resolved (BIO 4), and logs the same line.
        let argv = try await fixture.expectedArgv()
        let preview = ViralReconWorkflowCommandPreview.build(
            executableName: argv[0],
            arguments: Array(argv.dropFirst())
        )
        XCTAssertEqual(item.cliCommand, preview)
        XCTAssertTrue(item.logEntries.map(\.message).contains(preview), "\(item.logEntries.map(\.message))")
        // The record names the preview for the run and for its one step. Its
        // other argv is the copy of the specialist prompt into the revision.
        let recordArgvs = try GenotypeAIHaplotypingRunFixture.argvArrays(inRecordAt: published.provenanceURL)
        XCTAssertEqual(recordArgvs.filter { $0.first == CLICommandIdentity.executableName }, [argv, argv])
        XCTAssertEqual(fixture.server.requests.map(\.path), ["/openai/v1/responses"])
    }

    /// `GenotypeAIHaplotypingExecutionService.run` records a command the
    /// shipped parser reads back as the run it made.
    func testRecordedCommandParsesAsTheResolvedAIHaplotypingRun() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let service: GenotypeAIHaplotypingExecutionService = fixture.makeService()
        try await service.run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)

        let recorded = fixture.operationCenter.items.first?.cliCommand
        let command = try RecordedCLICommand.parse(recorded, as: GenotypeAIHaplotypingSubcommand.self)
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        XCTAssertEqual(command.bundle, fixture.bundleURL.standardizedFileURL.path)
        XCTAssertEqual(command.mode, .aiDiscovery)
        XCTAssertEqual(command.provider, .openAI)
        XCTAssertEqual(command.model, fixture.deployment)
        XCTAssertEqual(command.azureOpenAIEndpoint, fixture.server.baseURL.absoluteString)
        XCTAssertEqual(command.azureOpenAIDeployment, fixture.deployment)
        XCTAssertEqual(command.promptTemplateID, preset.aiPromptTemplateID(for: .aiDiscovery))
        XCTAssertEqual(command.promptTemplateVersion, preset.aiPromptTemplateVersion)
        XCTAssertEqual(command.maxObservationsPerChunk, 10_000)
        XCTAssertEqual(command.maxOutputTokens, 16_384)
        XCTAssertEqual(command.temperature, 0)
        XCTAssertEqual(command.reasoningEffort, preset.aiReasoningEffort)
        XCTAssertEqual(command.maxProviderRetries, 5)
        XCTAssertFalse(command.compactKnowledgePack)
        XCTAssertFalse(command.previewPrompt)
        XCTAssertNil(command.debugOutput)
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
        XCTAssertEqual(request.headerLines.filter { $0.contains(key) }.count, 1)
        XCTAssertTrue(request.headerLines.contains("api-key: " + key))
        XCTAssertFalse(request.target.contains(key))
        XCTAssertNil(request.body.range(of: Data(key.utf8)))
    }

    /// Q-S10 (5 to 0). The throwaway key reaches no argument of the recorded
    /// command or of the record, no row text, View Log line or failure sheet,
    /// no record the run wrote and no golden.
    func testThrowawayKeyReachesNoArgvRowLogSheetRecordOrGolden() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let published = try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)
        let key = fixture.throwawayKey

        let recorded = try RecordedCLICommand.arguments(of: fixture.operationCenter.items.first?.cliCommand)
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertFalse(recorded.contains { $0.contains(key) }, "the key reached the recorded command")
        let recordArgvs = try GenotypeAIHaplotypingRunFixture.argvArrays(inRecordAt: published.provenanceURL)
        XCTAssertFalse(recordArgvs.joined().contains { $0.contains(key) }, "the key reached the record's argv")
        XCTAssertFalse(fixture.rowTexts().contains { $0.contains(key) }, "the key reached the row or its log")
        XCTAssertEqual(try fixture.filesContaining(key), [], "the key reached a record")

        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: golden.path))
        XCTAssertEqual(try fixture.filesContaining(key, under: golden), [], "the key reached a golden")
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

    /// Review fix 3 (QA 2). A sidecar written between `prepare` and `begin`
    /// changes the bundle state, so the run reads the bundle again under the
    /// lock and publishes against the sidecar that now exists.
    func testSidecarWrittenBetweenPrepareAndBeginIsReadAgainSoThePublishIsNotStale() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let service = fixture.makeService()
        let bundleURL = fixture.bundleURL
        service.afterPrepareForTesting = {
            do {
                try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                    .empty(generatedAt: "2026-10-18T00:00:00Z"),
                    forBundleAt: bundleURL
                )
            } catch {
                XCTFail("The hook could not write a sidecar: \(error)")
            }
        }
        try await service.run(bundleURL: bundleURL, mode: .aiDiscovery)

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(item.state, .completed)
        let argv = try await fixture.expectedArgv()
        XCTAssertEqual(item.cliCommand, Self.preview(argv))
    }

    /// Review fixes 2 and 3 (ARCH 2, BIO 4). A manifest rewritten between
    /// `prepare` and `begin` moves the prompt pins, so the row takes the
    /// command the run used, the revision's argv equals it, and View Log
    /// says the command moved.
    func testBundleChangeThatMovesThePromptPinsUpdatesTheRowCommand() async throws {
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self, specialistManifest: false)
        let firstArgv = try await fixture.expectedArgv()
        let service = fixture.makeService()
        service.afterPrepareForTesting = {
            do {
                try fixture.writeManifest(specialist: true)
            } catch {
                XCTFail("The hook could not rewrite the manifest: \(error)")
            }
        }
        let published = try await service.run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)

        let item = try XCTUnwrap(fixture.operationCenter.items.first)
        XCTAssertEqual(item.state, .completed)
        let usedArgv = try await fixture.expectedArgv()
        XCTAssertNotEqual(usedArgv, firstArgv, "the rewrite must move the prompt pins")
        let recordArgvs = try GenotypeAIHaplotypingRunFixture.argvArrays(inRecordAt: published.provenanceURL)
        XCTAssertEqual(recordArgvs.filter { $0.first == CLICommandIdentity.executableName }, [usedArgv, usedArgv])
        XCTAssertEqual(item.cliCommand, Self.preview(usedArgv))
        XCTAssertTrue(
            item.logEntries.contains { $0.message.contains("the row now records the command this run used") },
            "\(item.logEntries.map(\.message))"
        )
    }

    private static func preview(_ argv: [String]) -> String {
        ViralReconWorkflowCommandPreview.build(executableName: argv[0], arguments: Array(argv.dropFirst()))
    }
}
