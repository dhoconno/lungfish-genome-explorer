// GenotypeAIHaplotypingRunFixture.swift - One AI Haplotyping run against a recorded provider response
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.19 (L11, Q-S10). The fixture writes an MCM MiSeq genotype
// bundle with one sample, points the OpenAI hosted endpoint setting at a
// loopback stand-in that answers a recorded Responses API reply, and puts a
// throwaway API key in an in-memory secret lookup, so no run reads or writes
// a keychain and none skips when the login keychain is locked. The settings
// go to a test defaults suite, never `UserDefaults.standard`.

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
    /// A key no provider accepts. It is fixed so that X15 of the 2.12 plan can
    /// grep gate logs, goldens and these runs' records for it, and the tests
    /// never print it in a failure message.
    nonisolated static let throwawayKey = "sk-lgeL11-throwaway-qs10-5e0c1d7a"
    let throwawayKey = GenotypeAIHaplotypingRunFixture.throwawayKey
    let deployment = "lane-12-19-recorded-deployment"
    let root: URL
    let bundleURL: URL
    let server: LoopbackHTTPStandIn
    let secrets: InMemoryProviderSecrets
    let operationCenter = OperationCenter()

    /// The recorded structured reply, one MHC-A call for the fixture sample.
    nonisolated static let recordedPayload = #"{"calls":[{"sample":"LF2823","locus":"MHC-A","h1":"M4A","h2":"?"}]}"#

    static let mcm0069Header = "MCM_MHC_MiSeq_0069|source_loci=MHC-A1|haplotype_groups=MHC-A|haplotypes=M4|alleles=Mafa-A1_031:01:01:01|accessions=OR823430|length=156|evidence_classes=primary_expressed|max_evidence_weight=1.00|evidence_weight_sum=1.00"

    /// - Parameters:
    ///   - storesKey: Whether the in-memory secret lookup holds the throwaway OpenAI key.
    ///   - providerStatus: The HTTP status the stand-in answers. 200 sends the recorded reply.
    ///   - specialistManifest: Whether the manifest names the MCM MiSeq preset, so the run
    ///     resolves the specialist prompt pins. Without them it resolves the general prompt.
    ///   - preferredProvider: The provider the settings prefer, or nil for the settings default.
    init(
        testCase: XCTestCase,
        storesKey: Bool = true,
        providerStatus: Int = 200,
        specialistManifest: Bool = true,
        preferredProvider: String? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-12-19-ai-haplotyping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = root
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        bundleURL = try Self.writeBundle(in: root, specialistManifest: specialistManifest)

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
        if let preferredProvider {
            settings.preferredAIProvider = preferredProvider
        }

        secrets = InMemoryProviderSecrets(storesKey ? [KeychainSecretStorage.openAIAPIKey: throwawayKey] : [:])
    }

    func makeService() -> GenotypeAIHaplotypingExecutionService {
        GenotypeAIHaplotypingExecutionService(
            operationCenter: operationCenter,
            settings: .shared,
            keychain: secrets
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

    /// The relative path of every file under `directory`, the fixture root by
    /// default, whose bytes hold `needle`.
    func filesContaining(_ needle: String, under directory: URL? = nil) throws -> [String] {
        let root = directory ?? root
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

    /// Rewrites the bundle's manifest, with or without the MCM MiSeq preset's
    /// definition set and assay, which decide the prompt pins of the command.
    func writeManifest(specialist: Bool) throws {
        try Self.writeManifest(in: bundleURL, specialist: specialist)
    }

    private static let bundleName = "LF2823-mcm"

    private static func writeManifest(in bundleURL: URL, specialist: Bool) throws {
        let name = bundleName
        let preset = MCMHaplotypingPreset.mcmMHCmiseq
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: name,
            analysisName: name,
            primaryWorkbookPath: "\(name).xlsx",
            longSummaryCSVPath: "\(name).genotypes.csv",
            sampleSummaryCSVPath: "\(name).samples.csv",
            statsJSONPath: "\(name).stats.json",
            provenancePath: "genotyping-provenance.json",
            haplotypeDefinitionSetID: specialist ? preset.haplotypeDefinitionSetID : nil,
            haplotypeAssayID: specialist ? preset.haplotypeAssayID : nil
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
    }

    private static func writeBundle(in root: URL, specialistManifest: Bool) throws -> URL {
        let name = bundleName
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
        try writeManifest(in: bundleURL, specialist: specialistManifest)
        return bundleURL
    }
}

/// The provider keys of one fixture, held in memory. It stands in for the
/// login keychain, so a run resolves its key with no credential store.
actor InMemoryProviderSecrets: AIProviderSecretLookup {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    func retrieve(forKey key: String) -> String? {
        values[key]
    }
}
