import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3AlleleContractTests: XCTestCase {
    func testCapabilitiesRequireFrozenLGE4AlleleContract() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(fixture.capabilities)
        XCTAssertFalse(capabilities.source.isEmpty)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.capabilities) as? [String: Any])
        var allele = try XCTUnwrap(root["alleleCoverage"] as? [String: Any])
        allele["metric"] = "full-span/v0"
        root["alleleCoverage"] = allele
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateCapabilities(
            JSONSerialization.data(withJSONObject: root)))
    }

    func testAuditReceiptBindsEveryNativeByteAndRejectsMutationOrMissingEvidence() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(fixture.capabilities)
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: nil, auditProvenance: nil))
        try Data("mutated selected oligo\n".utf8).write(
            to: fixture.output.appendingPathComponent("stages/strict/assignments.json"))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance))
    }

    private struct Fixture {
        let root: URL
        let output: URL
        let capabilities: Data
        let configuration: [String: Any]
        let options: PrimalScheme3DesignOptions
        let argv: [String]
        let auditValidation: Data
        let auditProvenance: Data
    }

    private static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = root.appendingPathComponent("native", isDirectory: true)
        let stage = output.appendingPathComponent("stages/strict", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.fasta")
        try Data(">row A\nACGTNRYTACGT\n".utf8).write(to: source)
        let stored = output.appendingPathComponent("work/0000-input.fasta")
        try FileManager.default.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: stored)
        let history = output.appendingPathComponent("history/history.sqlite")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sqlite-fixture".utf8).write(to: history)
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, coreCount: 1,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 280,
            selectionAlgorithm: .alleleCoverage)
        let resolved = resolvedOptions(options)
        let profile: [String: Any] = ["name": "allele-panel-v1", "specificity_revision": "selected-sites-v2"]
        let integration: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-native-integration/v2",
            "selectionAlgorithm": "allele-coverage", "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "primaryTier": "strict", "profile": profile, "options": resolved,
            "optimizer": ["path": "panel-optimizer.json", "schemaVersion": "primalscheme3.panel-optimizer/v2"],
            "validation": ["path": "panel-validation.json", "schemaVersion": "primalscheme3.allele-panel-validation/v2", "valid": true],
            "provenance": ["path": "panel-provenance.json", "schemaVersion": "primalscheme3.panel-provenance/v1"],
            "publication": [:]
        ]
        let resolvedData = try JSONSerialization.data(withJSONObject: resolved, options: [.sortedKeys])
        let configuration: [String: Any] = [
            "version": PrimalScheme3DesignPipeline.alleleToolVersion,
            "selection_algorithm": "allele-coverage", "coverage_metric": "observed-allele-primer-trimmed",
            "coverage_target": 0.95, "mode": "equal", "mapping": "first",
            "terminal_gap_policy": "observed-only", "discovery_backend": "python-observed-only",
            "n_pools": 2, "ncores": 1, "discovery_core_count": 1,
            "amplicon_size": 200, "amplicon_size_min": 150, "amplicon_size_max": 280,
            "amplicon_size_metric": "reference-span", "allele_options_json": String(decoding: resolvedData, as: UTF8.self),
            "panel_optimizer": integration
        ]
        try writeJSON(configuration, to: output.appendingPathComponent("config.json"))
        let optimizer: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-optimizer/v2", "algorithm": "bounded-allele-coverage/v1",
            "metric": "observed-allele-primer-trimmed/v1", "primaryTier": "strict", "profile": profile,
            "options": resolved, "publication": [:], "timings": [:],
            "history": ["path": "history/history.sqlite", "configurationLedger": "configuration-ledger.json.gz", "counts": [:]],
            "stages": [["path": "stages/strict", "stage_id": "strict", "assignments": [],
                        "coverage": [:], "optimizer": [:], "validationValid": true]]
        ]
        try writeJSON(optimizer, to: output.appendingPathComponent("panel-optimizer.json"))
        try writeJSON(["schemaVersion": "primalscheme3.allele-panel-validation/v2", "valid": true],
                      to: output.appendingPathComponent("panel-validation.json"))
        try writeGzip(["schema_version": "primalscheme3.variant-catalog/v2"],
                      to: output.appendingPathComponent("discovery-catalog.json.gz"))
        try writeGzip(["schema_version": "primalscheme3.configuration-ledger/v2"],
                      to: output.appendingPathComponent("configuration-ledger.json.gz"))
        for name in ["catalog.json.gz", "ledger.json.gz", "authoritative-targets.json.gz"] {
            try writeGzip(["schema_version": name == "catalog.json.gz" ? "primalscheme3.variant-catalog/v2" : "fixture"],
                          to: stage.appendingPathComponent(name))
        }
        for name in ["assignments.json", "coverage.json", "validation.json", "stage.json"] {
            try writeJSON(["fixture": true], to: stage.appendingPathComponent(name))
        }
        try Data("fixture\t0\t180\tamplicon\n".utf8).write(to: output.appendingPathComponent("amplicon.bed"))
        try Data("fixture\t0\t20\tprimer\t1\t+\tACGT\n".utf8).write(to: output.appendingPathComponent("primer.bed"))
        try Data(">fixture\nACGT\n".utf8).write(to: output.appendingPathComponent("reference.fasta"))

        let identitySource: [String: Any] = ["root": "/fixture/source", "kind": "git", "commit": "fixture"]
        let identityRuntime: [String: Any] = ["pythonExecutable": "/fixture/python", "pythonVersion": "3.12"]
        let capabilitiesObject: [String: Any] = [
            "schemaVersion": "primalscheme3.capabilities/v1", "tool": "primalscheme3",
            "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "selectionAlgorithms": ["legacy", "coverage", "allele-coverage"],
            "alleleCoverage": [
                "sourceContractVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
                "algorithm": "bounded-allele-coverage/v1", "metric": "observed-allele-primer-trimmed/v1",
                "preset": "allele-balanced-v1", "catalogSchemaVersion": "primalscheme3.variant-catalog/v2",
                "configurationLedgerSchemaVersion": "primalscheme3.configuration-ledger/v2",
                "validationSchemaVersion": "primalscheme3.allele-panel-validation/v2",
                "profile": ["name": "allele-panel-v1", "specificityRevision": "selected-sites-v2"],
                "supportedScope": ["mode": "equal", "mapping": "first", "ampliconSizeMetric": "reference-span",
                    "freshDesign": true, "linear": true, "suppliedMsaSpecificity": true,
                    "terminalGapPolicies": ["observed-only"]]
            ], "source": identitySource, "runtime": identityRuntime
        ]
        let argv = ["/fixture/primalscheme3", "panel-create", "--msa", source.path, "--output", output.path]
        let nativeBeforeProvenance = try regularFiles(output)
        let nativeOutputs = try nativeBeforeProvenance.map { try descriptor($0, relativeTo: output) }
        let inputDescriptor: [String: Any] = [
            "sourceIndex": 0, "sourcePath": source.path, "storedPath": "work/0000-input.fasta",
            "sha256": try ProvenanceFileHasher.sha256(of: stored), "size": try ProvenanceFileHasher.fileSize(of: stored),
            "sourceChangedDuringRun": false, "storedMissing": false
        ]
        let provenance: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-provenance/v1", "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "status": "success", "exitStatus": 0, "sourceChangedDuringRun": false, "runtimeChangedDuringRun": false,
            "source": identitySource, "sourceAtEnd": identitySource, "runtime": identityRuntime, "runtimeAtEnd": identityRuntime,
            "inputs": [inputDescriptor], "outputs": nativeOutputs
        ]
        try writeJSON(provenance, to: output.appendingPathComponent("panel-provenance.json"))
        let auditValidationObject: [String: Any] = [
            "valid": true, "raw_inputs_reparsed": true, "primary_tier": "strict",
            "scope": "stored-original-inputs-and-fresh-selected-stage-kernels",
            "stages": ["strict": ["valid": true]]
        ]
        let auditValidation = try JSONSerialization.data(withJSONObject: auditValidationObject, options: [.sortedKeys])
        let auditOutput: [String: Any] = ["path": "validation.json", "sha256": sha256(auditValidation),
                                                  "size": auditValidation.count]
        let audit: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-inspection-provenance/v1",
            "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion, "status": "success", "exitStatus": 0,
            "inputChangedDuringRun": false, "sourceChangedDuringRun": false, "runtimeChangedDuringRun": false,
            "source": identitySource, "sourceAtEnd": identitySource, "runtime": identityRuntime, "runtimeAtEnd": identityRuntime,
            "command": ["argv": ["/fixture/primalscheme3", "panel-audit", "--bundle", output.path,
                                    "--output", root.appendingPathComponent("audit").path],
                        "shell": "fixture", "workingDirectory": root.path],
            "inputs": try regularFiles(output).map { try descriptor($0, relativeTo: output) },
            "outputs": [auditOutput]
        ]
        return .init(root: root, output: output,
                     capabilities: try JSONSerialization.data(withJSONObject: capabilitiesObject),
                     configuration: configuration, options: options, argv: argv,
                     auditValidation: auditValidation,
                     auditProvenance: try JSONSerialization.data(withJSONObject: audit))
    }

    private static func resolvedOptions(_ options: PrimalScheme3DesignOptions) -> [String: Any] {
        let a = options.alleleOptions
        return [
            "preset": a.preset, "candidate_profiles": a.candidateProfiles, "variant_selection": a.variantSelection,
            "allele_weighting": a.alleleWeighting, "discovery_length_mode": a.discoveryLengthMode,
            "specificity_terminal_k": a.specificityTerminalK, "secondary_product_policy": a.secondaryProductPolicy,
            "subset_beam_width": a.subsetBeamWidth, "subset_expansion_limit": a.subsetExpansionLimit,
            "exchange_width": a.exchangeWidth, "salvage": a.salvage, "salvage_thresholds": a.salvageThresholds,
            "salvage_max_stages": a.salvageMaxStages, "salvage_max_edges_per_pool": a.salvageMaxEdgesPerPool,
            "salvage_max_oligos_per_pool": a.salvageMaxOligosPerPool, "salvage_time_limit": a.salvageTimeLimit,
            "primary_tier": a.primaryTier, "coverage_metric": options.coverageMetric.rawValue,
            "coverage_target": options.coverageTarget, "requested_options": [:],
            "work_frontier_candidates": a.workFrontierCandidates,
            "work_construction_candidate_attempts": a.workConstructionCandidateAttempts,
            "work_repair_candidate_probes_per_round": a.workRepairCandidateProbesPerRound,
            "work_repair_neighborhoods_per_round": a.workRepairNeighborhoodsPerRound,
            "work_repair_trials_per_round": a.workRepairTrialsPerRound,
            "work_pool_lookahead_candidates": a.workPoolLookaheadCandidates,
            "work_cleanup_moves_per_round": a.workCleanupMovesPerRound,
            "work_families_per_refresh": a.workFamiliesPerRefresh
        ]
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func writeGzip(_ object: Any, to url: URL) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c"]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: object))
        try input.fileHandleForWriting.close()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try compressed.write(to: url)
    }

    private static func regularFiles(_ root: URL) throws -> [URL] {
        let values = try root.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values.isRegularFile == true { return [root] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }.flatMap(regularFiles)
    }

    private static func descriptor(_ file: URL, relativeTo root: URL) throws -> [String: Any] {
        ["path": file.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/"), "sha256": try ProvenanceFileHasher.sha256(of: file),
         "size": try ProvenanceFileHasher.fileSize(of: file)]
    }

    private static func sha256(_ data: Data) -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try! ProvenanceFileHasher.sha256(of: temporary)
    }
}
