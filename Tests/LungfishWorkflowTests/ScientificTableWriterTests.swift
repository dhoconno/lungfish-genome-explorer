import Foundation
import XCTest
@testable import LungfishWorkflow

final class ScientificTableWriterTests: XCTestCase {
    private final class CellTextParser: NSObject, XMLParserDelegate {
        var targetReference = ""
        var value = ""
        private var isTargetCell = false
        private var isText = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "c" { isTargetCell = attributeDict["r"] == targetReference }
            if elementName == "t", isTargetCell { isText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isText { value += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "t" { isText = false }
            if elementName == "c" { isTargetCell = false }
        }
    }
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func incrementAndRead() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScientificTableWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixture: ScientificTableData {
        ScientificTableData(
            name: "Variants",
            columns: [
                .init(id: "gene", title: "Gene"),
                .init(id: "position", title: "Position (1-based)"),
                .init(id: "frequency", title: "AF"),
                .init(id: "missing", title: "Missing"),
            ],
            rows: [
                [.text("SEPT1"), .integer(29_409), .number(0.999628), .empty],
                [.text("00123"), .text("9007199254740993"), .text("=1+1"), .text("1|0")],
                [.text("a,\"b\"\r\nc"), .integer(-7), .number(-0.25), .boolean(true)],
            ]
        )
    }

    func testCSVUsesExactTypedValuesAndEscapesCRLFQuotesAndFormulaText() throws {
        let output = directory.appendingPathComponent("variants.csv")
        try ScientificTableWriter.write(fixture, format: .csv, to: output)
        let text = try String(contentsOf: output, encoding: .utf8)

        XCTAssertTrue(text.contains("SEPT1,29409,0.999628,"))
        XCTAssertTrue(text.contains("00123,9007199254740993,'=1+1,1|0"))
        XCTAssertTrue(text.contains("\"a,\"\"b\"\"\r\nc\",-7,-0.25,true"))
    }

    func testJSONPreservesColumnIDsOrderAndTypedCells() throws {
        let output = directory.appendingPathComponent("variants.json")
        try ScientificTableWriter.write(fixture, format: .json, to: output)
        let decoded = try JSONDecoder().decode(ScientificTableData.self, from: Data(contentsOf: output))

        XCTAssertEqual(decoded.columns.map(\.id), ["gene", "position", "frequency", "missing"])
        XCTAssertEqual(decoded.rows[0], [.text("SEPT1"), .integer(29_409), .number(0.999628), .empty])
        XCTAssertEqual(decoded.rows[1][1], .text("9007199254740993"))
    }

    func testXLSXRetainsTextIdentifiersAndFormulaTextAsInlineStrings() throws {
        let output = directory.appendingPathComponent("variants.xlsx")
        try ScientificTableWriter.write(fixture, format: .xlsx, to: output)
        let extraction = directory.appendingPathComponent("xlsx", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", output.path, "-d", extraction.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let sheet = try String(
            contentsOf: extraction.appendingPathComponent("xl/worksheets/sheet1.xml"),
            encoding: .utf8
        )
        XCTAssertTrue(sheet.contains("<c r=\"A3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">00123</t>"))
        XCTAssertTrue(sheet.contains("<c r=\"B3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">9007199254740993</t>"))
        XCTAssertTrue(sheet.contains("<c r=\"C3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">=1+1</t>"))
        XCTAssertFalse(sheet.contains("<f>"))
        XCTAssertTrue(sheet.contains("<v>29409</v>"))
        XCTAssertTrue(sheet.contains("<v>0.999628</v>"))
        XCTAssertTrue(sheet.contains("<pane ySplit=\"1\""))
        XCTAssertTrue(sheet.contains("<autoFilter"))
        let parserDelegate = CellTextParser()
        parserDelegate.targetReference = "A4"
        let parser = XMLParser(data: Data(sheet.utf8))
        parser.delegate = parserDelegate
        XCTAssertTrue(parser.parse())
        XCTAssertEqual(parserDelegate.value, "a,\"b\"\r\nc")
    }

    func testRejectsNonRectangularAndExcelLimitViolationsWithCSVGuidance() throws {
        let malformed = ScientificTableData(
            name: "Broken",
            columns: [.init(id: "a", title: "A")],
            rows: [[.text("a"), .text("b")]]
        )
        XCTAssertThrowsError(try ScientificTableWriter.write(
            malformed, format: .csv, to: directory.appendingPathComponent("bad.csv")
        ))

        let tooLong = ScientificTableData(
            name: "Broken",
            columns: [.init(id: "a", title: "A")],
            rows: [[.text(String(repeating: "x", count: 32_768))]]
        )
        XCTAssertThrowsError(try ScientificTableWriter.write(
            tooLong, format: .xlsx, to: directory.appendingPathComponent("bad.xlsx")
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("CSV"))
        }
    }

    func testCancellationDoesNotLeaveACompletedWriterOutput() throws {
        let output = directory.appendingPathComponent("cancel.csv")
        let checks = LockedCounter()
        XCTAssertThrowsError(try ScientificTableWriter.write(fixture, format: .csv, to: output) {
            checks.incrementAndRead() > 1
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
