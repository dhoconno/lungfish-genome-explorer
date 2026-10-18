// GenotypeAIHaplotypingRunFixture.swift - One AI Haplotyping run against a recorded provider response
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.19 (L11, Q-S10). The fixture writes an MCM MiSeq genotype
// bundle with one sample, points the OpenAI hosted endpoint setting at a
// loopback stand-in that answers a recorded Responses API reply, and puts a
// throwaway API key on a stand-in keychain service that no app build reads.
// The settings go to a test defaults suite, never `UserDefaults.standard`.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class GenotypeAIHaplotypingRunFixture {
    /// A key no provider accepts, unique to this fixture, so a grep for it
    /// finds only what this run wrote.
    let throwawayKey = "sk-lane1219-throwaway-\(UUID().uuidString)"
    let deployment = "lane-12-19-recorded-deployment"
    let root: URL
    let bundleURL: URL
    let server: LoopbackHTTPStandIn
    let keychain: KeychainSecretStorage
    let operationCenter = OperationCenter()

    /// The recorded structured reply, one MHC-A call for the fixture sample.
    nonisolated static let recordedPayload = #"{"calls":[{"sample":"LF2823","locus":"MHC-A","h1":"M4A","h2":"?"}]}"#

    static let mcm0069Header = "MCM_MHC_MiSeq_0069|source_loci=MHC-A1|haplotype_groups=MHC-A|haplotypes=M4|alleles=Mafa-A1_031:01:01:01|accessions=OR823430|length=156|evidence_classes=primary_expressed|max_evidence_weight=1.00|evidence_weight_sum=1.00"

    /// - Parameters:
    ///   - storesKey: Whether the stand-in keychain holds the throwaway OpenAI key.
    ///   - providerStatus: The HTTP status the stand-in answers. 200 sends the recorded reply.
    init(testCase: XCTestCase, storesKey: Bool = true, providerStatus: Int = 200) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-12-19-ai-haplotyping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = root
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        bundleURL = try Self.writeBundle(in: root)

        server = try LoopbackHTTPStandIn.start { _ in
            Self.recordedResponse(status: providerStatus)
        }
        let server = server
        testCase.addTeardownBlock { server.stop() }

        let suite = testCase.makeTestDefaultsSuite(prefix: "lane-12-19-ai-haplotyping")
        let restoreSettings = AppSettings.isolateForTesting(defaults: suite.defaults)
        testCase.addTeardownBlock { @MainActor in restoreSettings() }
        let settings = AppSettings.shared
        settings.openAIHostedEndpointEnabled = true
        settings.openAIHostedEndpointKind = "azure"
        settings.openAIHostedEndpoint = server.baseURL.absoluteString
        settings.openAIHostedDeployment = deployment

        keychain = KeychainSecretStorage(service: "org.lungfish.tests.lane-12-19.\(UUID().uuidString)")
        let keychain = keychain
        testCase.addTeardownBlock {
            try? await keychain.delete(forKey: KeychainSecretStorage.openAIAPIKey)
            try? await keychain.delete(forKey: KeychainSecretStorage.anthropicAPIKey)
        }
        if storesKey {
            do {
                try await keychain.store(secret: throwawayKey, forKey: KeychainSecretStorage.openAIAPIKey)
            } catch {
                throw XCTSkip("The login keychain refused a stand-in item (\(error)), so the run cannot resolve a key.")
            }
        }
    }

    func makeService() -> GenotypeAIHaplotypingExecutionService {
        GenotypeAIHaplotypingExecutionService(
            operationCenter: operationCenter,
            settings: .shared,
            keychain: keychain
        )
    }

    /// The command the run resolves, in the order `commandPreview` builds it.
    func expectedArgv() async throws -> [String] {
        let result = try await ONTGenotypeResultBundle.loadResultAsync(from: bundleURL)
        let selection = AIHaplotypingPromptSelectionResolver.resolve(
            result: result,
            mode: .aiDiscovery,
            requestedPromptTemplateID: nil,
            requestedPromptTemplateVersion: nil,
            compactKnowledgePack: true
        )
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        var argv = [
            CLICommandIdentity.executableName, "genotype", "ai-haplotyping",
            "--bundle", bundleURL.standardizedFileURL.path,
            "--mode", "ai-discovery",
            "--provider", AIHaplotypingProviderID.openAI.rawValue,
            "--model", deployment,
            "--max-observations-per-chunk", "10000",
            "--max-output-tokens", "16384",
            "--temperature", "0",
            "--reasoning-effort", preset.aiReasoningEffort,
            "--max-provider-retries", "5",
        ]
        if selection.compactKnowledgePack {
            argv.append("--compact-knowledge-pack")
        }
        if let id = selection.promptTemplateID {
            argv += ["--prompt-template-id", id]
        }
        if let version = selection.promptTemplateVersion {
            argv += ["--prompt-template-version", version]
        }
        argv += [
            "--azure-openai-endpoint", server.baseURL.absoluteString,
            "--azure-openai-deployment", deployment,
        ]
        return argv
    }

    /// Every text the row shows: its fields, its View Log lines and its failure sheet.
    func rowTexts() -> [String] {
        operationCenter.items.flatMap { item -> [String] in
            [item.title, item.detail, item.cliCommand ?? "", item.errorMessage ?? "", item.errorDetail ?? ""]
                + item.logEntries.map(\.message)
                + [String(describing: item)]
        }
    }

    /// The relative path of every file under the fixture root whose bytes hold `needle`.
    func filesContaining(_ needle: String) throws -> [String] {
        let needleData = Data(needle.utf8)
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            if try Data(contentsOf: url).range(of: needleData) != nil {
                hits.append(String(url.path.dropFirst(root.path.count)))
            }
        }
        return hits
    }

    /// The `argv` arrays anywhere in the JSON record at `url`.
    static func argvArrays(inRecordAt url: URL) throws -> [[String]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var found: [[String]] = []
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "argv", let strings = child as? [String] {
                        found.append(strings)
                    } else {
                        visit(child)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(object)
        return found
    }

    private nonisolated static func recordedResponse(status: Int) -> LoopbackHTTPResponse {
        guard status == 200 else {
            let body = #"{"error":{"code":"lane_1219_recorded","message":"The recorded deployment refused the request."}}"#
            return LoopbackHTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
        }
        let reply: [String: Any] = [
            "id": "resp_lane_1219_recorded",
            "status": "completed",
            "output_text": recordedPayload,
            "usage": ["input_tokens": 100, "output_tokens": 12],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        return LoopbackHTTPResponse(status: 200, contentType: "application/json", body: body)
    }

    private static func writeBundle(in root: URL) throws -> URL {
        let name = "LF2823-mcm"
        let bundleURL = root.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("workbook".utf8).write(to: bundleURL.appendingPathComponent("\(name).xlsx"))
        try Data("sample,genotype,passed_alignments,passed_unique_reads\nLF2823,\(mcm0069Header),42,21\n".utf8)
            .write(to: bundleURL.appendingPathComponent("\(name).genotypes.csv"))
        try Data("sample,passed_alignments,passed_unique_reads\nLF2823,42,21\n".utf8)
            .write(to: bundleURL.appendingPathComponent("\(name).samples.csv"))
        try Data(#"{"totalInputReads":42,"retainedUniqueReads":21}"#.utf8)
            .write(to: bundleURL.appendingPathComponent("\(name).stats.json"))
        try Data(#"{"workflow":"lane-12-19"}"#.utf8)
            .write(to: bundleURL.appendingPathComponent("genotyping-provenance.json"))
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: name,
            analysisName: name,
            primaryWorkbookPath: "\(name).xlsx",
            longSummaryCSVPath: "\(name).genotypes.csv",
            sampleSummaryCSVPath: "\(name).samples.csv",
            statsJSONPath: "\(name).stats.json",
            provenancePath: "genotyping-provenance.json",
            haplotypeDefinitionSetID: preset.haplotypeDefinitionSetID,
            haplotypeAssayID: preset.haplotypeAssayID
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }
}
