import XCTest
import ArgumentParser
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class PrimerDesignCommandTests: XCTestCase {
    func testPrimalSchemeParsesIndependentAmpliconSizeBounds() throws {
        let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
            "--msa", "/tmp/mhc.lungfishmsa", "--output", "/tmp/result.lungfishprimeranalysis",
            "--amplicon-size", "200", "--amplicon-size-min", "150", "--amplicon-size-max", "250"])
        XCTAssertEqual(command.ampliconSize, 200)
        XCTAssertEqual(command.ampliconSizeMinimum, 150)
        XCTAssertEqual(command.ampliconSizeMaximum, 250)
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
}
