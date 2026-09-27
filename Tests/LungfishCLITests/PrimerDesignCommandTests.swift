import XCTest
import ArgumentParser
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class PrimerDesignCommandTests: XCTestCase {
    /// Primer3 considers no pair when the target cannot fit inside the maximum product, so
    /// the command must fail up front rather than exit 0 with an empty result.
    func testPrimer3RejectsTargetLongerThanTheMaximumProductSize() throws {
        let command = try PrimerDesignCommand.Primer3Subcommand.parse([
            "--fasta-record", "/tmp/mhc.fasta@0",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--assay", "qpcr-dye", "--target-start", "205", "--target-end", "474"])
        let productMax = Primer3AssayDefaults.defaults(for: .qpcrDye).productSizeMax
        XCTAssertGreaterThan(474 - 205 + 1, productMax)
        do {
            _ = try command.makeOptions()
            XCTFail("Expected an over-long target to be rejected.")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("270"), message)
            XCTAssertTrue(message.contains("\(productMax)"), message)
        }

        let fits = try PrimerDesignCommand.Primer3Subcommand.parse([
            "--fasta-record", "/tmp/mhc.fasta@0",
            "--output", "/tmp/result.lungfishprimeranalysis",
            "--assay", "qpcr-dye", "--target-start", "205",
            "--target-end", String(205 + productMax - 1)])
        XCTAssertNoThrow(try fits.makeOptions())
    }

    func testPrimalSchemeParsesIndependentAmpliconSizeBounds() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--amplicon-size", "200", "--amplicon-size-min", "150", "--amplicon-size-max", "250"])
        XCTAssertEqual(command.ampliconSize, 200)
        XCTAssertEqual(command.ampliconSizeMinimum, 150)
        XCTAssertEqual(command.ampliconSizeMaximum, 250)
    }

    func testPrimalSchemeOmittedBoundsDefaultToTenPercentOfTargetLikeTheGUI() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--amplicon-size", "400"])
        let resolved = try command.makeOptions()
        XCTAssertEqual(resolved.options.requestedAmpliconSizeMinimum, 360)
        XCTAssertEqual(resolved.options.requestedAmpliconSizeMaximum, 440)
        XCTAssertEqual(resolved.options.ampliconSizeMetric, "reference-span")
        let partial = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--amplicon-size", "400", "--amplicon-size-max", "500"])
        let partialOptions = try partial.makeOptions().options
        XCTAssertEqual(partialOptions.requestedAmpliconSizeMinimum, 360)
        XCTAssertEqual(partialOptions.requestedAmpliconSizeMaximum, 500)
        XCTAssertEqual(PrimalScheme3DesignOptions.defaultAmpliconSizeBounds(target: 400)?.minimum, 360)
        XCTAssertNil(PrimalScheme3DesignOptions.defaultAmpliconSizeBounds(target: 50))
    }

    func testPrimalSchemeParsesLegacySalvageGapParentAndGapExpansionControls() throws {
        let salvage = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--msa", "/tmp/b.lungfishmsa",
            "--output", "/tmp/result.lungfishprimeranalysis", "--grouping", "combined",
            "--legacy-salvage", "bounded", "--legacy-salvage-threshold=-28", "--legacy-salvage-threshold=-30",
            "--legacy-salvage-floor=-32", "--legacy-salvage-max-edges-per-pool", "6",
            "--legacy-salvage-max-incident-species-per-pool", "3", "--legacy-salvage-min-reference-gain", "2",
            "--legacy-salvage-max-candidate-evaluations", "500"])
        let salvageOptions = try salvage.makeOptions().options.legacySalvageOptions
        XCTAssertEqual(salvageOptions, PrimalScheme3LegacySalvageOptions(
            mode: .bounded, thresholds: [-28, -30], floor: -32, maxEdgesPerPool: 6,
            maxIncidentSpeciesPerPool: 3, minReferenceGain: 2, maxCandidateEvaluations: 500))
        XCTAssertEqual(salvageOptions.requestedOptionNames, ["mode", "thresholds", "floor", "maxEdgesPerPool",
            "maxIncidentSpeciesPerPool", "minReferenceGain", "maxCandidateEvaluations"])

        let followUp = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis", "--grouping", "combined",
            "--gap-completion-parent", "/tmp/parent.lungfishprimeranalysis",
            "--gap-expansion", "bounded", "--gap-expansion-max-anchors-per-msa", "500",
            "--gap-expansion-max-pairs-per-msa", "200"])
        let followUpOptions = try followUp.makeOptions().options
        XCTAssertEqual(followUpOptions.gapCompletionParent, URL(fileURLWithPath: "/tmp/parent.lungfishprimeranalysis").standardizedFileURL)
        XCTAssertEqual(followUpOptions.gapExpansionOptions,
                       PrimalScheme3GapExpansionOptions(mode: .bounded, maxAnchorsPerMSA: 500, maxPairsPerMSA: 200))

        let defaults = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis"])
        let defaultOptions = try defaults.makeOptions().options
        XCTAssertEqual(defaultOptions.legacySalvageOptions, .init())
        XCTAssertEqual(defaultOptions.gapExpansionOptions, .init())
        XCTAssertNil(defaultOptions.gapCompletionParent)

        let badSalvage = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis", "--legacy-salvage", "greedy"])
        XCTAssertThrowsError(try badSalvage.makeOptions())
        let badExpansion = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/a.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis", "--gap-expansion", "all"])
        XCTAssertThrowsError(try badExpansion.makeOptions())
    }

    func testPrimer3AssayModeSelectsThePresetAndKeepsPickInternalOligo() throws {
        let base = ["--fasta-record", "/tmp/mhc.fa@0", "--output", "/tmp/design.lungfishprimeranalysis"]
        XCTAssertEqual(try PrimerDesignCommand.Primer3Subcommand.parse(base).makeOptions(), .preset(.pcr))
        let dye = try PrimerDesignCommand.Primer3Subcommand.parse(base + ["--assay", "qpcr-dye"]).makeOptions()
        XCTAssertEqual(dye, .preset(.qpcrDye))
        let probe = try PrimerDesignCommand.Primer3Subcommand.parse(base + ["--assay", "qpcr-probe"]).makeOptions()
        XCTAssertEqual(probe, .preset(.qpcrProbe))
        XCTAssertTrue(probe.pickInternalOligo)
        let oligo = try PrimerDesignCommand.Primer3Subcommand.parse(base + ["--pick-internal-oligo"]).makeOptions()
        XCTAssertEqual(oligo.assayMode, .pcr)
        XCTAssertTrue(oligo.pickInternalOligo)
        let overridden = try PrimerDesignCommand.Primer3Subcommand.parse(
            base + ["--assay", "qpcr-dye", "--primer-min-tm", "59", "--primer-max-poly-x", "3", "--pair-count", "2"]).makeOptions()
        XCTAssertEqual(overridden.primerMinTm, 59)
        XCTAssertEqual(overridden.primerMaxPolyX, 3)
        XCTAssertEqual(overridden.pairCount, 2)
        XCTAssertEqual(overridden.productSizeMax, 150)
        XCTAssertThrowsError(try PrimerDesignCommand.Primer3Subcommand.parse(base + ["--assay", "sybr"]).makeOptions())
    }

    func testPrimer3ParsesExplicitFASTAAndMSATemplateSelections() throws {
        let command = try PrimerDesignCommand.Primer3Subcommand.parse([
            "--fasta-record", "/tmp/mhc.fa@1",
            "--msa-template", "/tmp/alleles.lungfishmsa@2",
            "--binding-site-policy", "exclude-variable-and-gapped-columns",
            "--output", "/tmp/design.lungfishprimeranalysis",
            "--product-size-min", "120", "--product-size-max", "300",
        ])
        XCTAssertEqual(command.fastaRecords, ["/tmp/mhc.fa@1"])
        XCTAssertEqual(command.msaTemplates, ["/tmp/alleles.lungfishmsa@2"])
        XCTAssertEqual(command.bindingSitePolicy, "exclude-variable-and-gapped-columns")
        XCTAssertEqual(command.productSizeMin, 120)
        XCTAssertEqual(command.productSizeMax, 300)
    }

    func testSelectionParserUsesFinalAtSignAndRejectsMissingIndex() throws {
        let parsed = try PrimerDesignCommand.parseIndexedPath("/tmp/a@b/mhc.fa@3", option: "--fasta-record")
        XCTAssertEqual(parsed.url.path, "/tmp/a@b/mhc.fa")
        XCTAssertEqual(parsed.index, 3)
        XCTAssertThrowsError(try PrimerDesignCommand.parseIndexedPath("/tmp/mhc.fa", option: "--fasta-record"))
        XCTAssertThrowsError(try PrimerDesignCommand.parseIndexedPath("/tmp/mhc.fa@-1", option: "--fasta-record"))
    }

    func testPrimalSchemeAcceptsNativeAndRawAlignedFASTAInputsAtCLIBoundary() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc-class-i.lungfishmsa",
            "--output", "/tmp/scheme.lungfishprimeranalysis",
        ])
        XCTAssertEqual(command.msaPaths, ["/tmp/mhc-class-i.lungfishmsa"])
        XCTAssertEqual(command.terminalGapPolicy, "observed-only")
        XCTAssertEqual(command.coreCount, PrimalScheme3DesignOptions.defaultCoreCount)
        let legacy = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--output", "/tmp/out.lungfishprimeranalysis", "--terminal-gap-policy", "legacy"])
        XCTAssertEqual(legacy.terminalGapPolicy, "legacy")
        XCTAssertEqual(
            try command.validatedInputURLs(paths: ["/tmp/raw-aligned.fasta", "/tmp/raw-aligned.fas"])
                .map(\ .lastPathComponent),
            ["raw-aligned.fasta", "raw-aligned.fas"]
        )
        XCTAssertThrowsError(try command.validatedInputURLs(paths: ["/tmp/proteins.faa"]))
    }

    func testPrimalSchemeParsesCoverageSelectorOptions() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--selection-algorithm", "coverage", "--coverage-metric", "primer-trimmed",
            "--coverage-target", "0.8", "--optimizer-seed=-3", "--optimizer-starts", "6",
            "--optimizer-repair-rounds", "1", "--optimizer-time-limit", "4.5",
            "--mispriming-product-size", "900", "--amplicon-size-min", "150",
        ])
        XCTAssertEqual(command.selectionAlgorithm, "coverage")
        XCTAssertEqual(command.coverageMetric, "primer-trimmed")
        XCTAssertEqual(command.coverageTarget, 0.8)
        XCTAssertEqual(command.optimizerSeed, -3)
        XCTAssertEqual(command.optimizerStarts, 6)
        XCTAssertEqual(command.optimizerRepairRounds, 1)
        XCTAssertEqual(command.optimizerTimeLimit, 4.5)
        XCTAssertEqual(command.misprimingProductSize, 900)
    }

    func testPrimalSchemeParsesNamedAlleleCoverageControls() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--selection-algorithm", "allele-coverage", "--primalscheme3-path", "/tmp/primalscheme3",
            "--amplicon-size", "200", "--amplicon-size-min", "150", "--amplicon-size-max", "250",
            "--preset", "allele-balanced-v1", "--candidate-profiles", "union",
            "--reuse-discovery", "/tmp/cache", "--variant-selection", "subsets", "--phase-scheduling", "reserved",
            "--intended-product-policy", "concrete-designated-sites",
            "--allele-weighting", "distinct-observed", "--discovery-length-mode", "all",
            "--specificity-terminal-k", "19", "--secondary-product-policy", "reject-secondary-products/v1",
            "--subset-beam-width", "8", "--subset-expansion-limit", "100", "--exchange-width", "1",
            "--salvage", "bounded", "--salvage-threshold=-28", "--salvage-threshold=-31",
            "--salvage-max-stages", "2", "--salvage-max-edges-per-pool", "5",
            "--salvage-max-oligos-per-pool", "3", "--salvage-time-limit", "20",
            "--primary-tier", "salvage-2", "--work-frontier-candidates", "20",
            "--work-construction-candidate-attempts", "200",
            "--work-repair-candidate-probes-per-round", "30",
            "--work-repair-neighborhoods-per-round", "40", "--work-repair-trials-per-round", "50",
            "--work-pool-lookahead-candidates", "3", "--work-cleanup-moves-per-round", "12",
            "--work-families-per-refresh", "7",
        ])

        XCTAssertEqual(command.selectionAlgorithm, "allele-coverage")
        XCTAssertEqual(command.preset, "allele-balanced-v1")
        XCTAssertEqual(command.candidateProfiles, "union")
        XCTAssertEqual(command.reuseDiscovery, "/tmp/cache")
        XCTAssertEqual(command.phaseScheduling, "reserved")
        XCTAssertEqual(command.intendedProductPolicy, "concrete-designated-sites")
        XCTAssertEqual(command.secondaryProductPolicy, "reject-secondary-products/v1")
        XCTAssertEqual(command.salvageThresholds, [-28, -31])
        XCTAssertEqual(command.primaryTier, "salvage-2")
        XCTAssertEqual(command.workFamiliesPerRefresh, 7)
    }

    func testPrimalSchemeParsesSearchEffortWithoutInventingIndividualOverrides() throws {
        let inherited = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--selection-algorithm", "allele-coverage", "--search-effort", "quality-v1",
        ])
        XCTAssertEqual(inherited.searchEffort, "quality-v1")
        XCTAssertNil(inherited.optimizerStarts)
        XCTAssertNil(inherited.optimizerRepairRounds)
        XCTAssertNil(inherited.optimizerTimeLimit)
        XCTAssertNil(inherited.workConstructionCandidateAttempts)
        XCTAssertNil(inherited.workFamiliesPerRefresh)

        let overridden = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--selection-algorithm", "allele-coverage", "--search-effort", "quality-v1",
            "--optimizer-starts", "4", "--optimizer-repair-rounds", "2",
            "--optimizer-time-limit", "120", "--work-construction-candidate-attempts", "2048",
            "--work-families-per-refresh", "16",
        ])
        XCTAssertEqual(overridden.optimizerStarts, 4)
        XCTAssertEqual(overridden.optimizerRepairRounds, 2)
        XCTAssertEqual(overridden.optimizerTimeLimit, 120)
        XCTAssertEqual(overridden.workConstructionCandidateAttempts, 2_048)
        XCTAssertEqual(overridden.workFamiliesPerRefresh, 16)
    }
}
