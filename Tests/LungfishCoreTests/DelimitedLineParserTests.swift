import Foundation
import Testing
@testable import LungfishCore

@Suite("DelimitedLineParser")
struct DelimitedLineParserTests {

    // MARK: - TSV quoting (BUG 2 regression guards)

    @Test("TSV quoted field containing an embedded tab is kept intact")
    func tsvQuotedEmbeddedTab() {
        let fields = DelimitedLineParser.fields(in: "\"a\tb\"\tc", delimiter: "\t")
        #expect(fields == ["a\tb", "c"])
    }

    @Test("TSV doubled-quote inside a quoted field is un-escaped")
    func tsvDoubledQuote() {
        let fields = DelimitedLineParser.fields(in: "\"x\"\"y\"\tz", delimiter: "\t")
        #expect(fields == ["x\"y", "z"])
    }

    // MARK: - Closing-quote handling (BUG 1 regression guards)

    @Test("Closing quote immediately followed by the delimiter ends the field")
    func closingQuoteThenDelimiter() {
        let fields = DelimitedLineParser.fields(in: "\"a\",b", delimiter: ",")
        #expect(fields == ["a", "b"])
    }

    @Test("Character immediately after a closing quote is appended to the same field")
    func charAfterClosingQuote() {
        // Documented behavior: closing quote sets inQuotes=false without consuming
        // the next char; the literal `x` is then appended to the same field before
        // the delimiter terminates it.
        let fields = DelimitedLineParser.fields(in: "\"a\"x,b", delimiter: ",")
        #expect(fields == ["ax", "b"])
    }

    // MARK: - Preserved CSV semantics (must not regress)

    @Test("Empty fields are preserved")
    func emptyFieldsPreserved() {
        #expect(DelimitedLineParser.fields(in: "a,,c", delimiter: ",") == ["a", "", "c"])
        #expect(DelimitedLineParser.fields(in: ",b", delimiter: ",") == ["", "b"])
        #expect(DelimitedLineParser.fields(in: "a,", delimiter: ",") == ["a", ""])
        #expect(DelimitedLineParser.fields(in: "", delimiter: ",") == [""])
    }

    @Test("Doubled quote inside a quoted CSV field is un-escaped")
    func csvDoubledQuoteUnescape() {
        // The whole field is quoted; the inner `""` un-escapes to a single `"`.
        let fields = DelimitedLineParser.fields(in: "\"she said \"\"hi\"\"\"", delimiter: ",")
        #expect(fields == ["she said \"hi\""])
    }

    @Test("Embedded delimiter inside a quoted CSV field stays in one field")
    func csvEmbeddedDelimiter() {
        let fields = DelimitedLineParser.fields(in: "\"Doe, Jane\"", delimiter: ",")
        #expect(fields == ["Doe, Jane"])
    }
}
