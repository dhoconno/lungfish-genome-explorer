import XCTest
@testable import LungfishWorkflow

final class AdvancedCommandLineOptionsTests: XCTestCase {
    func testParsesWhitespaceSeparatedArguments() throws {
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse("--meta --min-contig-len 500"),
            ["--meta", "--min-contig-len", "500"]
        )
    }

    func testParsesQuotedValuesAndEmbeddedQuotes() throws {
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse(#"--rg-id "sample 1" minid=0.97 --flag='two words'"#),
            ["--rg-id", "sample 1", "minid=0.97", "--flag=two words"]
        )
    }

    func testParsesBackslashEscapedWhitespace() throws {
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse(#"--tmp-dir /Volumes/Fast\ Scratch --tag alpha\ beta"#),
            ["--tmp-dir", "/Volumes/Fast Scratch", "--tag", "alpha beta"]
        )
    }

    func testRejectsUnterminatedQuote() {
        XCTAssertThrowsError(try AdvancedCommandLineOptions.parse(#"--rg-id "sample 1"#))
    }

    func testParsesEmptyQuotedArgument() throws {
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse(#"--tag "" --fallback ''"#),
            ["--tag", "", "--fallback", ""]
        )
    }

    func testJoinShellEscapesArgumentsForRoundTripDisplay() throws {
        let text = AdvancedCommandLineOptions.join(["--rg-id", "sample 1", "minid=0.97"])

        XCTAssertEqual(text, "--rg-id 'sample 1' minid=0.97")
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(text), ["--rg-id", "sample 1", "minid=0.97"])
    }

    func testJoinRoundTripsEmbeddedSingleQuote() throws {
        let arguments = ["--tag", "patient's sample"]
        let text = AdvancedCommandLineOptions.join(arguments)

        XCTAssertEqual(try AdvancedCommandLineOptions.parse(text), arguments)
    }
}
