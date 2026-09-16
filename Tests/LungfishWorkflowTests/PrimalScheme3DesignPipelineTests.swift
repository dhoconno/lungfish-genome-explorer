import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3DesignPipelineTests: XCTestCase {
    func testPrimalSchemeInputTreatsUnknownBasesAsMissingCoverage() {
        let result = Primer3InputLoader.normalizeForPrimalScheme([
            Primer3AlignedRow(title: "reference", sequence: "ACN-Uu"),
            Primer3AlignedRow(title: "sample", sequence: "AC--TT")
        ])

        XCTAssertEqual(result.rows.map(\.sequence), ["AC--TT", "AC--TT"])
        XCTAssertEqual(result.uracilCount, 2)
        XCTAssertEqual(result.unknownBaseCount, 1)
    }

    func testAlleleCoverageInputPreservesUnknownAndAmbiguousBases() {
        let result = Primer3InputLoader.normalizeForPrimalScheme([
            Primer3AlignedRow(title: "reference", sequence: "ACN-RYu"),
            Primer3AlignedRow(title: "sample", sequence: "ACG-NNt")
        ], ambiguityPolicy: .preserve)

        XCTAssertEqual(result.rows.map(\.sequence), ["ACN-RYT", "ACG-NNt"])
        XCTAssertEqual(result.uracilCount, 1)
        XCTAssertEqual(result.unknownBaseCount, 3)
    }

    func testSupportedInputsIncludeRawNucleotideFASTAAndNativeBundles() {
        for extensionName in ["fa", "fasta", "fna", "ffn", "frn", "fas", "lungfishmsa", "lungfishref"] {
            XCTAssertTrue(
                PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/reference.\(extensionName)")),
                extensionName
            )
        }
        XCTAssertFalse(PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/proteins.faa")))
        XCTAssertFalse(PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/reference.fa.gz")))
    }

    func testSingleSequenceReferenceBundleInspectsAsOneFASTARecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimalSchemeReferenceInput-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("synthetic.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(at: genome.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(">synthetic_reference\nACGTACGTACGT\n".utf8).write(to: genome)
        let manifest = BundleManifest(
            name: "Synthetic reference",
            identifier: "org.lungfish.tests.synthetic-reference",
            source: SourceInfo(organism: "Synthetic construct", assembly: "test-v1"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                totalLength: 12, chromosomes: [
                    ChromosomeInfo(name: "synthetic_reference", length: 12, offset: 21, lineBases: 12, lineWidth: 13)
                ]))
        try manifest.save(to: bundle)

        let summary = try await Primer3DesignPipeline.inspectInput(at: bundle)

        XCTAssertFalse(summary.isAlignment)
        XCTAssertEqual(summary.recordTitles, ["synthetic_reference"])
        XCTAssertEqual(summary.checksumSHA256, try Primer3InputLoader.fingerprint(bundle))
    }

    func testReferenceBundleDoesNotInferAlignmentFromMultipleSequences() {
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.validateReferenceBundleRows([
            Primer3AlignedRow(title: "synthetic_a", sequence: "ACGT"),
            Primer3AlignedRow(title: "synthetic_b", sequence: "TGCA")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one sequence"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("explicit alignment"), error.localizedDescription)
        }
    }

    func testExplicitAmpliconBoundsReachBothCommandsAndProvenance() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250)
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: grouping, options: options)
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--amplicon-size-min")) + 1], "150")
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--amplicon-size-max")) + 1], "250")
        }
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMinimum"], .integer(150))
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMaximum"], .integer(250))
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMetric"], .string("reference-span"))
        XCTAssertEqual(try JSONDecoder().decode(PrimalScheme3DesignOptions.self, from: JSONEncoder().encode(options)), options)
    }

    func testLegacyOptionsDecodeWithoutNewFieldsAndSingleExplicitBoundResolvesOther() throws {
        let original = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["requestedAmpliconSizeMinimum", "requestedAmpliconSizeMaximum", "selectionAlgorithm",
                    "coverageMetric", "coverageTarget", "optimizerSeed", "optimizerStarts",
                    "optimizerRepairRounds", "optimizerTimeLimit", "requestedMisprimingProductSize"] {
            payload.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(PrimalScheme3DesignOptions.self,
            from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.ampliconSizeMinimum, 180)
        XCTAssertEqual(decoded.ampliconSizeMaximum, 220)
        XCTAssertEqual(decoded.ampliconSizeMetric, "legacy-pairing")
        XCTAssertEqual(decoded.selectionAlgorithm, .legacy)
        XCTAssertEqual(decoded.coverageMetric, .fullSpan)
        XCTAssertEqual(decoded.coverageTarget, 0.90)
        XCTAssertEqual(decoded.optimizerSeed, 0)
        XCTAssertEqual(decoded.optimizerStarts, 4)
        XCTAssertEqual(decoded.optimizerRepairRounds, 2)
        XCTAssertEqual(decoded.optimizerTimeLimit, 120)
        XCTAssertNil(decoded.requestedMisprimingProductSize)
        XCTAssertEqual(decoded.misprimingProductSize, 0)
        let lower = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150)
        XCTAssertEqual(lower.ampliconSizeMaximum, 220)
        XCTAssertEqual(lower.ampliconSizeMetric, "reference-span")
    }

    func testInvalidExplicitAmpliconBoundsAreRejectedBeforeExecution() {
        for (minimum, maximum) in [(0, 250), (-1, 250), (251, 150), (201, 250), (150, 199)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: .independent,
                options: .init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: minimum, ampliconSizeMaximum: maximum)))
        }
    }

    func testNativeFullReferenceSpansMustHonorExplicitInclusiveBounds() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250)
        let bed = output.appendingPathComponent("amplicon.bed")
        for length in [150, 200, 250] {
            try "reference\t10\t\(10 + length)\tamplicon\t1\n".write(to: bed, atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try PrimalScheme3DesignPipeline.validateNativeAmpliconSpans(at: output, options: options))
        }
        for text in ["reference\t10\t159\ta\t1\n", "reference\t10\t261\ta\t1\n", "reference\t0\tbad\n", "reference\t-1\t200\n"] {
            try text.write(to: bed, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.validateNativeAmpliconSpans(at: output, options: options))
        }
    }

    func testSupportedPanelControlsAndEffectiveRange() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 401, poolCount: 2,
            dimerScore: -30, useMatchDB: false, panelMode: .entropy,
            maxAmplicons: 20, maxAmpliconsPerMSA: 5)
        XCTAssertEqual(options.ampliconSizeMinimum, 360)
        XCTAssertEqual(options.ampliconSizeMaximum, 441)
        let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
            output: URL(fileURLWithPath: "/o"), grouping: .combined, options: options)
        XCTAssertEqual(args[2], "entropy")
        XCTAssertTrue(args.contains("--no-use-matchdb"))
        XCTAssertTrue(args.contains("--max-amplicons-msa"))
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
            output: URL(fileURLWithPath: "/o"), grouping: .independent, options: options))
    }

    func testSchemeOnlyControlsRejectCombinedAndInvalidLimits() throws {
        for options in [PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2, backtrack: true),
            .init(ampliconSize: 400, poolCount: 2, ignoreN: true),
            .init(ampliconSize: 400, poolCount: 2, dimerScore: .nan),
            .init(ampliconSize: 400, poolCount: 2, maxAmplicons: 0)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
                output: URL(fileURLWithPath: "/o"), grouping: .combined, options: options))
        }
    }

    func testCombinedUsesOnePanelCreateWithEachAlignment() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2)
        let inputs = [URL(fileURLWithPath: "/test/first.fasta"), URL(fileURLWithPath: "/test/second.fasta")]
        let arguments = try PrimalScheme3DesignPipeline.arguments(
            inputs: inputs, output: URL(fileURLWithPath: "/test/output"),
            grouping: .combined, options: options)
        XCTAssertEqual(arguments, ["panel-create", "--mode", "equal", "--msa", inputs[0].path, "--msa", inputs[1].path,
            "--output", "/test/output", "--amplicon-size", "400", "--n-pools", "2",
            "--min-base-freq", "0.0", "--mapping", "first", "--no-high-gc", "--ncores", String(PrimalScheme3DesignOptions.defaultCoreCount), "--terminal-gap-policy", "observed-only", "--dimer-score", "-26.0", "--use-matchdb", "--offline-plots"])
        XCTAssertFalse(arguments.contains("--selection-algorithm"))
        XCTAssertFalse(arguments.contains("--mispriming-product-size"))
    }

    func testCoverageArgumentsForwardResolvedSelectorContract() throws {
        let inputs = [URL(fileURLWithPath: "/test/a.fasta"), URL(fileURLWithPath: "/test/b.fasta")]
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 3,
            terminalGapPolicy: .legacy, dimerScore: -27.5, panelMode: .equal,
            maxAmplicons: 0, maxAmpliconsPerMSA: 4, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, coverageMetric: .primerTrimmed,
            coverageTarget: 0.8, optimizerSeed: -7, optimizerStarts: 5,
            optimizerRepairRounds: 0, optimizerTimeLimit: 3.5)
        let args = try PrimalScheme3DesignPipeline.arguments(inputs: inputs,
            output: URL(fileURLWithPath: "/test/output"), grouping: .combined, options: options)
        for (flag, value) in [
            ("--selection-algorithm", "coverage"), ("--amplicon-size-min", "150"),
            ("--amplicon-size-max", "220"), ("--coverage-metric", "primer-trimmed"),
            ("--coverage-target", "0.8"), ("--optimizer-seed", "-7"),
            ("--optimizer-starts", "5"), ("--optimizer-repair-rounds", "0"),
            ("--optimizer-time-limit", "3.5"), ("--mispriming-product-size", "2000"),
            ("--max-amplicons", "0"), ("--max-amplicons-msa", "4")
        ] {
            let index = try XCTUnwrap(args.firstIndex(of: flag), flag)
            XCTAssertEqual(args[index + 1], value, flag)
        }
        XCTAssertEqual(options.provenanceOptions["selectionAlgorithm"], .string("coverage"))
        XCTAssertEqual(options.provenanceOptions["misprimingProductSize"], .integer(2000))
        XCTAssertEqual(options.provenanceOptions["requestedMisprimingProductSize"], .null)
    }

    func testAlleleCoverageDefaultsAndAdvancedControlsReachNativeArguments() throws {
        let inputs = [URL(fileURLWithPath: "/test/a.fasta"), URL(fileURLWithPath: "/test/b.fasta")]
        let allele = PrimalScheme3AlleleOptions(
            preset: "allele-balanced-v1", candidateProfiles: "normal",
            reuseDiscovery: URL(fileURLWithPath: "/cache"), variantSelection: "subsets",
            alleleWeighting: "distinct-observed", discoveryLengthMode: "all", specificityTerminalK: 19,
            secondaryProductPolicy: "reject-secondary-products/v1", subsetBeamWidth: 8,
            subsetExpansionLimit: 100, exchangeWidth: 1, salvage: "bounded",
            salvageThresholds: [-28, -31], salvageMaxStages: 2,
            salvageMaxEdgesPerPool: 5, salvageMaxOligosPerPool: 3,
            salvageTimeLimit: 20, primaryTier: "salvage-2",
            workFrontierCandidates: 20, workConstructionCandidateAttempts: 200,
            workRepairCandidateProbesPerRound: 30, workRepairNeighborhoodsPerRound: 40,
            workRepairTrialsPerRound: 50, workPoolLookaheadCandidates: 3,
            workCleanupMovesPerRound: 12, workFamiliesPerRefresh: 7)
        let options = PrimalScheme3DesignOptions(
            ampliconSize: 200, poolCount: 3, ampliconSizeMinimum: 150,
            ampliconSizeMaximum: 250, selectionAlgorithm: .alleleCoverage,
            optimizerSeed: -7, optimizerStarts: 5, optimizerRepairRounds: 0,
            optimizerTimeLimit: 3.5, alleleOptions: allele)

        let args = try PrimalScheme3DesignPipeline.arguments(inputs: inputs,
            output: URL(fileURLWithPath: "/test/output"), grouping: .combined, options: options)

        for (flag, value) in [
            ("--selection-algorithm", "allele-coverage"),
            ("--coverage-metric", "observed-allele-primer-trimmed"),
            ("--coverage-target", "0.95"), ("--candidate-profiles", "normal"),
            ("--reuse-discovery", "/cache"), ("--variant-selection", "subsets"),
            ("--allele-weighting", "distinct-observed"), ("--discovery-length-mode", "all"),
            ("--specificity-terminal-k", "19"),
            ("--secondary-product-policy", "reject-secondary-products/v1"),
            ("--subset-beam-width", "8"), ("--subset-expansion-limit", "100"),
            ("--exchange-width", "1"), ("--salvage", "bounded"),
            ("--salvage-max-stages", "2"), ("--salvage-max-edges-per-pool", "5"),
            ("--salvage-max-oligos-per-pool", "3"), ("--salvage-time-limit", "20.0"),
            ("--primary-tier", "salvage-2"), ("--work-frontier-candidates", "20"),
            ("--work-construction-candidate-attempts", "200"),
            ("--work-repair-candidate-probes-per-round", "30"),
            ("--work-repair-neighborhoods-per-round", "40"),
            ("--work-repair-trials-per-round", "50"),
            ("--work-pool-lookahead-candidates", "3"),
            ("--work-cleanup-moves-per-round", "12"),
            ("--work-families-per-refresh", "7")
        ] {
            let index = try XCTUnwrap(args.firstIndex(of: flag), flag)
            XCTAssertEqual(args[index + 1], value, flag)
        }
        XCTAssertEqual(args.filter { $0 == "--salvage-threshold" }.count, 2)
        XCTAssertEqual(options.coverageMetric, .observedAllelePrimerTrimmed)
        XCTAssertEqual(options.coverageTarget, 0.95)
        XCTAssertEqual(options.provenanceOptions["alleleOptions"], .dictionary(allele.resolvedProvenanceOptions))
        XCTAssertEqual(options.provenanceOptions["alleleRequestedOptions"], .dictionary(allele.requestedProvenanceOptions))
    }

    func testAlleleCoverageRejectsUnsupportedScopeAndInvalidAdvancedControls() {
        let input = [URL(fileURLWithPath: "/test/input.fasta")]
        let output = URL(fileURLWithPath: "/test/output")
        func rejected(_ options: PrimalScheme3DesignOptions, grouping: PrimerAnalysisGrouping = .combined,
                      file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: input, output: output,
                grouping: grouping, options: options), file: file, line: line)
        }
        rejected(.init(ampliconSize: 200, poolCount: 2, selectionAlgorithm: .alleleCoverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, highGC: true, ampliconSizeMinimum: 150,
            selectionAlgorithm: .alleleCoverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, terminalGapPolicy: .legacy,
            ampliconSizeMinimum: 150, selectionAlgorithm: .alleleCoverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, dimerScore: -28,
            ampliconSizeMinimum: 150, selectionAlgorithm: .alleleCoverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, minOverlap: 50,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250,
            selectionAlgorithm: .alleleCoverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .alleleCoverage,
            alleleOptions: .init(salvage: "off", salvageMaxStages: 2)))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .alleleCoverage,
            alleleOptions: .init(variantSelection: "full-cloud", subsetBeamWidth: 8)))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .alleleCoverage, coverageTarget: 0))
        XCTAssertNoThrow(try PrimalScheme3DesignPipeline.arguments(inputs: input, output: output,
            grouping: .combined, options: .init(ampliconSize: 200, poolCount: 2,
                ampliconSizeMinimum: 150, ampliconSizeMaximum: 250,
                selectionAlgorithm: .alleleCoverage)))
    }

    func testAlleleSalvageDefaultsFollowRequestedMaximumStageAndStrictTierIsAllowedWhenOff() throws {
        let bounded = PrimalScheme3AlleleOptions(salvage: "bounded", salvageMaxStages: 1)
        XCTAssertEqual(bounded.salvageThresholds, [-28])
        XCTAssertNoThrow(try bounded.validate())
        let strict = PrimalScheme3AlleleOptions(salvage: "off", primaryTier: "strict")
        XCTAssertNoThrow(try strict.validate())
    }

    func testAlleleReuseAcceptsOnlyConsistentZeroDiscoveryWorkers() throws {
        let cache = URL(fileURLWithPath: "/fixture/cache")
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250,
            selectionAlgorithm: .alleleCoverage,
            alleleOptions: .init(reuseDiscovery: cache))
        let valid: [String: Any] = ["discovery_core_count": 0, "discovery_reused": true,
            "discovery_workers_by_msa": ["0": 0],
            "discovery_workers_by_target_profile": ["target": ["normal": 0, "high-gc": 0]]]
        XCTAssertEqual(try PrimalScheme3DesignPipeline.validateEffectiveWorkers(
            configuration: valid, options: options), 0)
        for invalid in [
            ["discovery_core_count": 1, "discovery_reused": true,
             "discovery_workers_by_msa": ["0": 0],
             "discovery_workers_by_target_profile": ["target": ["normal": 0]]],
            ["discovery_core_count": 0, "discovery_reused": false,
             "discovery_workers_by_msa": ["0": 0],
             "discovery_workers_by_target_profile": ["target": ["normal": 0]]],
            ["discovery_core_count": 0, "discovery_reused": true,
             "discovery_workers_by_msa": ["0": 1],
             "discovery_workers_by_target_profile": ["target": ["normal": 0]]]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.validateEffectiveWorkers(
                configuration: invalid, options: options))
        }
    }

    func testCoverageRequiresCombinedEqualExplicitBoundsAndValidSelectorNumbers() {
        let input = [URL(fileURLWithPath: "/test/input.fasta")]
        let output = URL(fileURLWithPath: "/test/output")
        func rejected(_ options: PrimalScheme3DesignOptions, grouping: PrimerAnalysisGrouping = .combined,
                      file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: input, output: output,
                grouping: grouping, options: options), file: file, line: line)
        }
        rejected(.init(ampliconSize: 200, poolCount: 2, selectionAlgorithm: .coverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage), grouping: .independent)
        rejected(.init(ampliconSize: 200, poolCount: 2, panelMode: .entropy,
            ampliconSizeMinimum: 150, selectionAlgorithm: .coverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, useMatchDB: false,
            ampliconSizeMinimum: 150, selectionAlgorithm: .coverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, coverageTarget: .nan))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, coverageTarget: 1.01))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, optimizerStarts: 0))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, optimizerRepairRounds: -1))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, optimizerTimeLimit: .infinity))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, optimizerTimeLimit: 0))
        rejected(.init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150,
            selectionAlgorithm: .coverage, misprimingProductSize: 0))
        rejected(.init(ampliconSize: 200, poolCount: 2, maxAmplicons: -1,
            ampliconSizeMinimum: 150, selectionAlgorithm: .coverage))
        rejected(.init(ampliconSize: 200, poolCount: 2, maxAmpliconsPerMSA: -1,
            ampliconSizeMinimum: 150, selectionAlgorithm: .coverage))
        XCTAssertNoThrow(try PrimalScheme3DesignPipeline.arguments(inputs: input, output: output,
            grouping: .combined, options: .init(ampliconSize: 200, poolCount: 2,
                maxAmplicons: 0, maxAmpliconsPerMSA: 0, ampliconSizeMinimum: 150,
                selectionAlgorithm: .coverage)))
    }

    func testLegacyRejectsNondefaultSelectorSettingsButAcceptsExplicitZeroProductSize() throws {
        let input = [URL(fileURLWithPath: "/test/input.fasta")]
        let output = URL(fileURLWithPath: "/test/output")
        let accepted = try PrimalScheme3DesignPipeline.arguments(inputs: input, output: output,
            grouping: .combined, options: .init(ampliconSize: 200, poolCount: 2,
                misprimingProductSize: 0))
        XCTAssertFalse(accepted.contains("--mispriming-product-size"))
        for options in [
            PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, coverageTarget: 0.8),
            .init(ampliconSize: 200, poolCount: 2, optimizerSeed: 1),
            .init(ampliconSize: 200, poolCount: 2, optimizerStarts: 5),
            .init(ampliconSize: 200, poolCount: 2, optimizerRepairRounds: 3),
            .init(ampliconSize: 200, poolCount: 2, optimizerTimeLimit: 121),
            .init(ampliconSize: 200, poolCount: 2, misprimingProductSize: 1)
        ] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: input,
                output: output, grouping: .combined, options: options))
        }
    }

    func testAdvancedOptionsRespectVerifiedSubcommandCapabilities() throws {
        let input = URL(fileURLWithPath: "/test/input.fasta")
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2,
            minOverlap: 25, minimumBaseFrequency: 0.5, highGC: true, coreCount: 3, terminalGapPolicy: .legacy)
        let argv = try PrimalScheme3DesignPipeline.arguments(inputs: [input],
            output: URL(fileURLWithPath: "/test/output"), grouping: .independent, options: options)
        XCTAssertEqual(Array(argv.dropLast(8).suffix(9)), ["--min-base-freq", "0.5", "--mapping", "first",
            "--high-gc", "--ncores", "3", "--terminal-gap-policy", "legacy"])
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [input],
            output: URL(fileURLWithPath: "/test/output"), grouping: .combined, options: options))
        for invalid in [
            PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2, minOverlap: -1),
            .init(ampliconSize: 400, poolCount: 2, minimumBaseFrequency: .nan),
            .init(ampliconSize: 400, poolCount: 2, minimumBaseFrequency: 1.01),
            .init(ampliconSize: 400, poolCount: 2, coreCount: 0)
        ] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [input],
                output: URL(fileURLWithPath: "/test/output"), grouping: .independent, options: invalid))
        }
    }

    func testLegacyPolicyIsExplicitForBothGroupingModes() throws {
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: grouping,
                options: .init(ampliconSize: 400, poolCount: 2, terminalGapPolicy: .legacy))
            let flag = try XCTUnwrap(args.firstIndex(of: "--terminal-gap-policy"))
            XCTAssertEqual(args[flag + 1], "legacy")
        }
    }

    func testBothPoliciesPassSelectedCPUCount() throws {
        for policy in PrimalScheme3TerminalGapPolicy.allCases {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: .independent,
                options: .init(ampliconSize: 400, poolCount: 2, coreCount: 4, terminalGapPolicy: policy))
            let coreFlag = try XCTUnwrap(args.firstIndex(of: "--ncores"))
            let policyFlag = try XCTUnwrap(args.firstIndex(of: "--terminal-gap-policy"))
            XCTAssertEqual(args[coreFlag + 1], "4")
            XCTAssertEqual(args[policyFlag + 1], policy.rawValue)
        }
    }

    func testIndependentRejectsMultipleInputsAndInvalidOptions() {
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
            inputs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            output: URL(fileURLWithPath: "/o"), grouping: .independent,
            options: .init(ampliconSize: 400, poolCount: 2)))
        XCTAssertEqual(PrimalScheme3DesignOptions(ampliconSize: .max, poolCount: 2).ampliconSizeMaximum, 0)
        for options in [PrimalScheme3DesignOptions(ampliconSize: 0, poolCount: 2),
                        PrimalScheme3DesignOptions(ampliconSize: .max, poolCount: 2),
                        PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 0)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
                inputs: [URL(fileURLWithPath: "/a")], output: URL(fileURLWithPath: "/o"),
                grouping: .independent, options: options))
        }
    }
}
