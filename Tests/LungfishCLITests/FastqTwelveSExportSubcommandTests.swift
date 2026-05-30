import XCTest
@testable import LungfishCLI

final class FastqTwelveSExportSubcommandTests: XCTestCase {
    func testFastqCommandRegistersTwelveSExportCommands() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("12s-export"))
        XCTAssertTrue(names.contains("12s-export-unresolved"))
    }

    func testTwelveSExportParsesFilters() throws {
        let command = try FastqTwelveSExportSubcommand.parse([
            "--bundle", "/tmp/result.lungfish12s",
            "--export-format", "tsv",
            "--output", "/tmp/result.tsv",
            "--min-exact-reads", "5",
            "--filter", "canis",
            "--taxon-group", "Mammal",
            "--exclude-taxon-group", "Fish",
            "--exclude-human",
            "--require-alternate-matches",
            "--min-unresolved-reads", "7",
            "--chimera-status", "candidate",
            "--force",
        ])

        XCTAssertEqual(command.bundle, "/tmp/result.lungfish12s")
        XCTAssertEqual(command.format, .tsv)
        XCTAssertEqual(command.output, "/tmp/result.tsv")
        XCTAssertEqual(command.minimumExactReads, 5)
        XCTAssertEqual(command.filterText, "canis")
        XCTAssertEqual(command.taxonGroups, ["Mammal"])
        XCTAssertEqual(command.excludedTaxonGroups, ["Fish"])
        XCTAssertTrue(command.excludeHuman)
        XCTAssertTrue(command.requireAlternateMatches)
        XCTAssertEqual(command.minimumUnresolvedReads, 7)
        XCTAssertEqual(command.chimeraFilter, .candidate)
        XCTAssertTrue(command.force)
    }

    func testRootArgumentNormalizerRewritesTwelveSExportFormatToAvoidGlobalFormatConflict() {
        let normalized = LungfishCLI.normalizedArgumentsForParsing([
            "fastq", "12s-export",
            "--bundle", "/tmp/result.lungfish12s",
            "--format", "csv",
            "--output", "/tmp/result.csv",
        ])

        XCTAssertEqual(
            normalized,
            [
                "fastq", "12s-export",
                "--bundle", "/tmp/result.lungfish12s",
                "--export-format", "csv",
                "--output", "/tmp/result.csv",
            ]
        )
    }

    func testTwelveSExportUnresolvedParsesThreshold() throws {
        let command = try FastqTwelveSExportUnresolvedSubcommand.parse([
            "--bundle", "/tmp/result.lungfish12s",
            "--min-reads", "5",
            "--include-chimera-candidates",
            "--sequence-id", "unresolved_2",
            "--output", "/tmp/unresolved.fasta",
            "--force",
        ])

        XCTAssertEqual(command.bundle, "/tmp/result.lungfish12s")
        XCTAssertEqual(command.minimumReads, 5)
        XCTAssertTrue(command.includeChimeraCandidates)
        XCTAssertEqual(command.sequenceIDs, ["unresolved_2"])
        XCTAssertEqual(command.output, "/tmp/unresolved.fasta")
        XCTAssertTrue(command.force)
    }
}
