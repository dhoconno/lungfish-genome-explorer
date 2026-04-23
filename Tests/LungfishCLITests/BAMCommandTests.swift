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
        XCTAssertTrue(BAMCommand.helpMessage().contains("annotate"))
        XCTAssertTrue(BAMCommand.helpMessage().contains("lungfish-cli bam filter"))
        XCTAssertTrue(BAMCommand.helpMessage().contains("lungfish-cli bam annotate"))
        XCTAssertTrue(BAMCommand.FilterSubcommand.helpMessage().contains("mapping analysis directory"))
        XCTAssertTrue(BAMCommand.FilterSubcommand.helpMessage().contains("Output format: text, json"))
        XCTAssertFalse(BAMCommand.FilterSubcommand.helpMessage().contains("tsv"))
        XCTAssertTrue(BAMCommand.AnnotateSubcommand.helpMessage().contains("Convert mapped reads to annotations"))
        XCTAssertTrue(BAMCommand.AnnotateSubcommand.helpMessage().contains("Output format: text, json"))
        XCTAssertFalse(BAMCommand.AnnotateSubcommand.helpMessage().contains("tsv"))
        XCTAssertTrue(BAMCommand.MarkdupSubcommand.helpMessage().contains("Output format: text, json"))
        XCTAssertFalse(BAMCommand.MarkdupSubcommand.helpMessage().contains("tsv"))
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
            "--mapping-result", "/tmp/Run",
            "--alignment-track", "aln-2",
            "--output-track-name", "Identity >= 99",
            "--min-percent-identity", "99",
        ])

        XCTAssertNil(command.bundlePath)
        XCTAssertEqual(command.mappingResultPath, "/tmp/Run")
        XCTAssertEqual(command.alignmentTrackID, "aln-2")
        XCTAssertEqual(command.outputTrackName, "Identity >= 99")
        XCTAssertEqual(command.minimumPercentIdentity, 99)
    }

    func testFilterSubcommandRequiresExactlyOneTarget() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--mapping-result", "/tmp/Run",
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

    func testFilterSubcommandRejectsLegacyNameAlias() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--alignment-track", "aln-1",
                "--name", "Filtered",
            ])
        )
    }

    func testFilterSubcommandRejectsBlankBundlePath() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "   ",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--bundle"))
        }
    }

    func testFilterSubcommandRejectsBlankMappingResultPath() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--mapping-result", "   ",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--mapping-result"))
        }
    }

    func testFilterSubcommandRejectsBlankOutputTrackName() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--alignment-track", "aln-1",
                "--output-track-name", "   ",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("--output-track-name"))
        }
    }

    func testFilterSubcommandRejectsTSVOutputFormatAtParseTime() {
        XCTAssertThrowsError(
            try BAMCommand.FilterSubcommand.parse([
                "filter",
                "--bundle", "/tmp/Test.lungfishref",
                "--alignment-track", "aln-1",
                "--output-track-name", "Filtered",
                "--format", "tsv",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("tsv"))
        }
    }

    func testMarkdupSubcommandRejectsTSVOutputFormatAtParseTime() {
        XCTAssertThrowsError(
            try BAMCommand.MarkdupSubcommand.parse([
                "markdup",
                "/tmp/test.bam",
                "--format", "tsv",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("tsv"))
        }
    }
}
