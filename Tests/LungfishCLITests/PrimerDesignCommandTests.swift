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
}
