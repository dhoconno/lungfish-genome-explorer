import XCTest
@testable import LungfishCLI

final class BAMCommandTests: XCTestCase {
    func testRootHelpUsesCanonicalExecutableName() {
        XCTAssertEqual(LungfishCLI.configuration.commandName, "lungfish-cli")
        XCTAssertTrue(LungfishCLI.helpMessage().contains("bam"))
    }

    func testBamCommandNameAndHelp() {
        XCTAssertEqual(BAMCommand.configuration.commandName, "bam")
        XCTAssertTrue(BAMCommand.helpMessage().contains("filter"))
    }

    func testFilterSubcommandParsesBundleTargetAndFlags() throws {
        let command = try BAMCommand.FilterSubcommand.parse([
            "filter",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--output-track-name", "Exact Match Reads",
            "--mapped-only",
            "--primary-only",
            "--min-mapq", "42",
            "--exclude-marked-duplicates",
            "--exact-match",
            "--format", "json",
        ])

        XCTAssertEqual(command.bundlePath, "/tmp/Test.lungfishref")
        XCTAssertNil(command.mappingResultPath)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.outputTrackName, "Exact Match Reads")
        XCTAssertTrue(command.mappedOnly)
        XCTAssertTrue(command.primaryOnly)
        XCTAssertEqual(command.minimumMAPQ, 42)
        XCTAssertTrue(command.excludeMarkedDuplicates)
        XCTAssertFalse(command.removeDuplicates)
        XCTAssertTrue(command.exactMatch)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testFilterSubcommandParsesMappingResultTargetAndPercentIdentity() throws {
        let command = try BAMCommand.FilterSubcommand.parse([
            "filter",
            "--mapping-result", "/tmp/Run/mapping-result.json",
            "--alignment-track", "aln-2",
            "--output-track-name", "Identity >= 99",
            "--min-percent-identity", "99",
        ])

        XCTAssertNil(command.bundlePath)
        XCTAssertEqual(command.mappingResultPath, "/tmp/Run/mapping-result.json")
        XCTAssertEqual(command.alignmentTrackID, "aln-2")
        XCTAssertEqual(command.outputTrackName, "Identity >= 99")
        XCTAssertEqual(command.minimumPercentIdentity, 99)
    }

    func testFilterSubcommandRequiresExactlyOneTarget() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--mapping-result", "/tmp/Run/mapping-result.json",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("exactly one of --bundle or --mapping-result"))
        }
    }

    func testFilterSubcommandRejectsConflictingDuplicateModes() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
                "--exclude-marked-duplicates",
                "--remove-duplicates",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--exclude-marked-duplicates"))
        }
    }

    func testFilterSubcommandRejectsConflictingIdentityFilters() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
                "--exact-match",
                "--min-percent-identity", "99",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--exact-match"))
        }
    }
}
