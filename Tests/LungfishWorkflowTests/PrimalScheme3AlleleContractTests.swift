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
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.capabilities) as? [String: Any])
        var runtime = try XCTUnwrap(root["runtime"] as? [String: Any])
        runtime["nativeKernels"] = [["distribution": "primer3-py", "version": "2.2.0"]]
        root["runtime"] = runtime
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateCapabilities(
            JSONSerialization.data(withJSONObject: root)))
    }

    func testExplicitPhaseSchedulingRequiresFrozenCapabilityDescriptor() throws {
        let legacy = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: legacy.root) }
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateCapabilities(legacy.capabilities))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateCapabilities(
            legacy.capabilities, requestedPhaseScheduling: .serial))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateCapabilities(
            legacy.capabilities, requestedPhaseScheduling: .reserved))

        let current = try Self.makeFixture(phaseScheduling: .reserved, advertisePhaseScheduling: true)
        defer { try? FileManager.default.removeItem(at: current.root) }
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateCapabilities(
            current.capabilities, requestedPhaseScheduling: .reserved))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: current.capabilities) as? [String: Any])
        var allele = try XCTUnwrap(root["alleleCoverage"] as? [String: Any])
        var phase = try XCTUnwrap(allele["phaseScheduling"] as? [String: Any])
        var policies = try XCTUnwrap(phase["policies"] as? [String: Any])
        var reserved = try XCTUnwrap(policies["reserved"] as? [String: Any])
        reserved["initial_weights"] = ["seeds": 0.3, "construction": 0.3, "repair": 0.4]
        policies["reserved"] = reserved; phase["policies"] = policies
        allele["phaseScheduling"] = phase; root["alleleCoverage"] = allele
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateCapabilities(
            JSONSerialization.data(withJSONObject: root), requestedPhaseScheduling: .reserved))

        let currentDefault = try Self.makeFixture(advertisePhaseScheduling: true)
        defer { try? FileManager.default.removeItem(at: currentDefault.root) }
        let defaultCapabilities = try PrimalScheme3AlleleContract.validateCapabilities(currentDefault.capabilities)
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: currentDefault.output, configuration: currentDefault.configuration,
            capabilities: defaultCapabilities, options: currentDefault.options, inputCount: 1,
            executedArgv: currentDefault.argv, auditValidation: currentDefault.auditValidation,
            auditProvenance: currentDefault.auditProvenance,
            auditExecutedArgv: currentDefault.auditArgv, auditExitStatus: 0))
    }

    func testSchedulingPolicyAndProgressAreBoundToSelectedCapabilityDescriptor() throws {
        let fixture = try Self.makeFixture(phaseScheduling: .reserved, advertisePhaseScheduling: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(
            fixture.capabilities, requestedPhaseScheduling: .reserved)
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0))

        let optimizerURL = fixture.output.appendingPathComponent("panel-optimizer.json")
        var optimizer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: optimizerURL)) as? [String: Any])
        var stages = try XCTUnwrap(optimizer["stages"] as? [[String: Any]])
        var stageOptimizer = try XCTUnwrap(stages[0]["optimizer"] as? [String: Any])
        stageOptimizer["scheduling_policy"] = ["id": "serial/v1"]
        stages[0]["optimizer"] = stageOptimizer; optimizer["stages"] = stages
        try Self.writeJSON(optimizer, to: optimizerURL)
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0)) { error in
                XCTAssertTrue(error.localizedDescription.contains("scheduling policy"))
            }
        stageOptimizer["scheduling_policy"] = Self.reservedSchedulingPolicy()
        let validStageOptimizer = stageOptimizer
        stageOptimizer.removeValue(forKey: "phase_progress")
        stages[0]["optimizer"] = stageOptimizer; optimizer["stages"] = stages
        try Self.writeJSON(optimizer, to: optimizerURL)
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0)) { error in
                XCTAssertTrue(error.localizedDescription.contains("phase progress"))
            }

        var malformedProgress = validStageOptimizer
        var progress = try XCTUnwrap(malformedProgress["phase_progress"] as? [[String: Any]])
        progress[0].removeValue(forKey: "objective_after")
        malformedProgress["phase_progress"] = progress
        stages[0]["optimizer"] = malformedProgress; optimizer["stages"] = stages
        try Self.writeJSON(optimizer, to: optimizerURL)
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0)) { error in
                XCTAssertTrue(error.localizedDescription.contains("objective_after"))
            }
    }

    func testAuditReceiptBindsEveryNativeByteAndRejectsMutationOrMissingEvidence() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(fixture.capabilities)
        XCTAssertNoThrow(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: nil, auditProvenance: nil, auditExecutedArgv: nil, auditExitStatus: nil))
        try Data("mutated selected oligo\n".utf8).write(
            to: fixture.output.appendingPathComponent("stages/strict/assignments.json"))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0))
    }

    func testContractRejectsWrongNestedOptionsDetachedCommandsAndPartialAudit() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(fixture.capabilities)
        var wrong = fixture.configuration
        var integration = try XCTUnwrap(wrong["panel_optimizer"] as? [String: Any])
        var nested = try XCTUnwrap(integration["options"] as? [String: Any])
        nested["optimizer_seed"] = 99
        integration["options"] = nested; wrong["panel_optimizer"] = integration
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: wrong, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0))
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv + ["--detached"],
            auditValidation: fixture.auditValidation, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv, auditExitStatus: 0))
        let partial = try JSONSerialization.data(withJSONObject: [
            "valid": true, "raw_inputs_reparsed": true, "primary_tier": "strict",
            "scope": "stored-original-inputs-and-fresh-selected-stage-kernels", "stages": [:]
        ])
        XCTAssertThrowsError(try PrimalScheme3AlleleContract.validateNativeOutput(
            at: fixture.output, configuration: fixture.configuration, capabilities: capabilities,
            options: fixture.options, inputCount: 1, executedArgv: fixture.argv,
            auditValidation: partial, auditProvenance: fixture.auditProvenance,
            auditExecutedArgv: fixture.auditArgv + ["--tier", "strict"], auditExitStatus: 0))
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
        let auditArgv: [String]
    }

    private static func makeFixture(phaseScheduling: PrimalScheme3PhaseScheduling? = nil,
                                    advertisePhaseScheduling: Bool = false) throws -> Fixture {
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
            selectionAlgorithm: .alleleCoverage,
            alleleOptions: .init(phaseScheduling: phaseScheduling))
        let resolved = resolvedOptions(options, includePhaseScheduling: advertisePhaseScheduling)
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
        var stageOptimizer: [String: Any] = [:]
        if advertisePhaseScheduling {
            stageOptimizer = [
                "scheduling_policy": phaseScheduling == .reserved ? reservedSchedulingPolicy() : serialSchedulingPolicy(),
                "objective_terms": [
                    "negative-mean-utility", "negative-mean-coverage", "negative-worst-coverage",
                    "violating-edges", "incident-species", "sequence-pool-instances", "assignments",
                    "pool-burden-range", "size-deviation", "canonical-assignments"
                ],
                "phase_progress": [[
                    "phase": "construction:0", "outcome": "completed",
                    "started_seconds": 0.0,
                    "local_budget_seconds": phaseScheduling == .reserved ? 10.0 : NSNull(),
                    "elapsed_seconds": 0.1, "local_overshoot_seconds": 0.0,
                    "objective_before": Array(repeating: 0.0, count: 9),
                    "objective_after": Array(repeating: 0.0, count: 9),
                    "repairs_accepted_delta": 0,
                    "work_delta": [:], "proposal_work_delta": [:],
                    "family_cursors_before": [:], "family_cursors": [:]
                ]]
            ]
        }
        let optimizer: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-optimizer/v2", "algorithm": "bounded-allele-coverage/v1",
            "metric": "observed-allele-primer-trimmed/v1", "primaryTier": "strict", "profile": profile,
            "options": resolved, "publication": [:], "timings": [:],
            "history": ["path": "history/history.sqlite", "configurationLedger": "configuration-ledger.json.gz", "counts": [:]],
            "stages": [["path": "stages/strict", "stage_id": "strict", "assignments": [],
                        "coverage": [:], "optimizer": stageOptimizer, "validationValid": true]]
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

        let digest = String(repeating: "a", count: 64)
        let identitySource: [String: Any] = ["root": "/fixture/source", "kind": "git", "gitCommit": "fixture",
            "sourceDigest": digest, "build": ["path": "pyproject.toml", "sha256": digest, "size": 1],
            "files": [["path": "primalscheme3/cli.py", "sha256": digest, "size": 1]]]
        let identityRuntime: [String: Any] = ["pythonExecutable": "/fixture/python",
            "pythonExecutableResolved": "/fixture/python3.12", "pythonVersion": "3.12",
            "pythonImplementation": "CPython", "pythonPrefix": "/fixture", "platform": "fixture-os",
            "machine": "arm64", "kernel": ["system": "Darwin"],
            "declaredRuntimeDependencies": [["distribution": "primer3-py", "version": "2.2.0"]],
            "nativeKernels": [["distribution": "primer3-py", "package": "primer3", "version": "2.2.0",
                "files": [["path": "/fixture/primer3.so", "sha256": digest, "size": 1]]]]]
        var alleleCapability: [String: Any] = [
            "sourceContractVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "algorithm": "bounded-allele-coverage/v1", "metric": "observed-allele-primer-trimmed/v1",
            "preset": "allele-balanced-v1", "catalogSchemaVersion": "primalscheme3.variant-catalog/v2",
            "configurationLedgerSchemaVersion": "primalscheme3.configuration-ledger/v2",
            "validationSchemaVersion": "primalscheme3.allele-panel-validation/v2",
            "profile": ["name": "allele-panel-v1", "specificityRevision": "selected-sites-v2"],
            "supportedScope": ["mode": "equal", "mapping": "first", "ampliconSizeMetric": "reference-span",
                "freshDesign": true, "linear": true, "suppliedMsaSpecificity": true,
                "terminalGapPolicies": ["observed-only"]]
        ]
        if advertisePhaseScheduling {
            alleleCapability["phaseScheduling"] = phaseSchedulingCapability()
        }
        let capabilitiesObject: [String: Any] = [
            "schemaVersion": "primalscheme3.capabilities/v1", "tool": "primalscheme3",
            "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "selectionAlgorithms": ["legacy", "coverage", "allele-coverage"],
            "alleleCoverage": alleleCapability, "source": identitySource, "runtime": identityRuntime
        ]
        var argv = ["/fixture/primalscheme3", "panel-create", "--msa", source.path, "--output", output.path]
        if let phaseScheduling { argv += ["--phase-scheduling", phaseScheduling.rawValue] }
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
            "inputs": [inputDescriptor], "outputs": nativeOutputs,
            "command": ["argv": argv, "shell": "fixture", "workingDirectory": root.path]
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
        let auditArgv = ["/fixture/primalscheme3", "panel-audit", "--bundle", output.path,
                         "--output", root.appendingPathComponent("audit").path]
        let audit: [String: Any] = [
            "schemaVersion": "primalscheme3.panel-inspection-provenance/v1",
            "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion, "status": "success", "exitStatus": 0,
            "inputChangedDuringRun": false, "sourceChangedDuringRun": false, "runtimeChangedDuringRun": false,
            "source": identitySource, "sourceAtEnd": identitySource, "runtime": identityRuntime, "runtimeAtEnd": identityRuntime,
            "command": ["argv": auditArgv,
                        "shell": "fixture", "workingDirectory": root.path],
            "inputs": try regularFiles(output).map { try descriptor($0, relativeTo: output) },
            "outputs": [auditOutput]
        ]
        return .init(root: root, output: output,
                     capabilities: try JSONSerialization.data(withJSONObject: capabilitiesObject),
                     configuration: configuration, options: options, argv: argv,
                     auditValidation: auditValidation,
                     auditProvenance: try JSONSerialization.data(withJSONObject: audit), auditArgv: auditArgv)
    }

    private static func resolvedOptions(_ options: PrimalScheme3DesignOptions,
                                        includePhaseScheduling: Bool = false) -> [String: Any] {
        let a = options.alleleOptions
        var requested: [String: Any] = [:]
        if a.requestedOptionNames.contains("phaseScheduling") {
            requested["phase_scheduling"] = a.phaseScheduling.rawValue
        }
        var result: [String: Any] = [
            "preset": a.preset, "candidate_profiles": a.candidateProfiles, "variant_selection": a.variantSelection,
            "allele_weighting": a.alleleWeighting, "discovery_length_mode": a.discoveryLengthMode,
            "specificity_terminal_k": a.specificityTerminalK, "secondary_product_policy": a.secondaryProductPolicy,
            "subset_beam_width": a.subsetBeamWidth, "subset_expansion_limit": a.subsetExpansionLimit,
            "exchange_width": a.exchangeWidth, "salvage": a.salvage, "salvage_thresholds": a.salvageThresholds,
            "salvage_max_stages": a.salvageMaxStages, "salvage_max_edges_per_pool": a.salvageMaxEdgesPerPool,
            "salvage_max_oligos_per_pool": a.salvageMaxOligosPerPool, "salvage_time_limit": a.salvageTimeLimit,
            "primary_tier": a.primaryTier, "coverage_metric": options.coverageMetric.rawValue,
            "coverage_target": options.coverageTarget, "requested_options": requested,
            "amplicon_size": options.ampliconSize, "amplicon_size_min": options.ampliconSizeMinimum,
            "amplicon_size_max": options.ampliconSizeMaximum, "n_pools": options.poolCount,
            "ncores": options.coreCount, "optimizer_seed": options.optimizerSeed,
            "optimizer_starts": options.optimizerStarts, "optimizer_repair_rounds": options.optimizerRepairRounds,
            "optimizer_time_limit": options.optimizerTimeLimit, "mismatch_product_size": options.misprimingProductSize,
            "min_base_freq": options.minimumBaseFrequency, "dimer_score": options.dimerScore,
            "max_amplicons": options.maxAmplicons ?? NSNull(),
            "max_amplicons_msa": options.maxAmpliconsPerMSA ?? NSNull(), "reuse_discovery": NSNull(),
            "work_frontier_candidates": a.workFrontierCandidates,
            "work_construction_candidate_attempts": a.workConstructionCandidateAttempts,
            "work_repair_candidate_probes_per_round": a.workRepairCandidateProbesPerRound,
            "work_repair_neighborhoods_per_round": a.workRepairNeighborhoodsPerRound,
            "work_repair_trials_per_round": a.workRepairTrialsPerRound,
            "work_pool_lookahead_candidates": a.workPoolLookaheadCandidates,
            "work_cleanup_moves_per_round": a.workCleanupMovesPerRound,
            "work_families_per_refresh": a.workFamiliesPerRefresh
        ]
        if includePhaseScheduling || a.requestedOptionNames.contains("phaseScheduling") {
            result["phase_scheduling"] = a.phaseScheduling.rawValue
        }
        return result
    }

    private static func serialSchedulingPolicy() -> [String: Any] { ["id": "serial/v1"] }
    private static func reservedSchedulingPolicy() -> [String: Any] {
        ["id": "initial-phase-reservations/v1",
         "initial_weights": ["seeds": 0.2, "construction": 0.4, "repair": 0.4],
         "repair_weights": ["preparation": 0.2, "cleanup": 0.2, "exchange": 0.6]]
    }
    private static func phaseSchedulingCapability() -> [String: Any] {
        ["default": "serial",
         "policies": ["serial": serialSchedulingPolicy(), "reserved": reservedSchedulingPolicy()]]
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
