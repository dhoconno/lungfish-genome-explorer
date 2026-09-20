import Foundation

public enum ScientificTableCell: Codable, Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case empty
}

public struct ScientificTableColumn: Codable, Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum ScientificTableFormat: String, Codable, Sendable, CaseIterable {
    case csv
    case tsv
    case json
    case xlsx
}

public struct ScientificTableData: Codable, Sendable, Equatable {
    public let name: String
    public let columns: [ScientificTableColumn]
    public let rows: [[ScientificTableCell]]

    public init(name: String, columns: [ScientificTableColumn], rows: [[ScientificTableCell]]) {
        self.name = name
        self.columns = columns
        self.rows = rows
    }
}

public struct ScientificTableWriteReport: Codable, Sendable, Equatable {
    public let archiveToolPath: String?
    public let archiveArgv: [String]?
    public let archiveToolVersion: String?

    public init(archiveToolPath: String? = nil, archiveArgv: [String]? = nil, archiveToolVersion: String? = nil) {
        self.archiveToolPath = archiveToolPath
        self.archiveArgv = archiveArgv
        self.archiveToolVersion = archiveToolVersion
    }
}

public enum ScientificTableWriterError: LocalizedError, Equatable {
    case cancelled
    case nonRectangular(row: Int, expected: Int, actual: Int)
    case tooManyColumns(Int)
    case tooManyRows(Int)
    case textTooLong(row: Int, column: Int)
    case invalidXML(row: Int, column: Int)
    case nonFiniteNumber(row: Int, column: Int)
    case integerExceedsExcelPrecision(row: Int, column: Int, value: Int64)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The table export was cancelled."
        case .nonRectangular(let row, let expected, let actual):
            return "Export row \(row + 1) has \(actual) cells; \(expected) were expected."
        case .tooManyColumns(let count):
            return "Excel supports at most 16,384 columns; this table has \(count). Use CSV instead."
        case .tooManyRows(let count):
            return "Excel supports at most 1,048,576 rows including the header; this table has \(count). Use CSV instead."
        case .textTooLong(let row, let column):
            return "Excel cell at row \(row + 1), column \(column + 1) exceeds 32,767 UTF-16 units. Use CSV instead."
        case .invalidXML(let row, let column):
            return "Cell at row \(row + 1), column \(column + 1) contains a character that XML cannot represent."
        case .nonFiniteNumber(let row, let column):
            return "Cell at row \(row + 1), column \(column + 1) contains a non-finite number."
        case .integerExceedsExcelPrecision(let row, let column, let value):
            return "Integer \(value) at row \(row + 1), column \(column + 1) exceeds Excel's exact numeric precision. Encode this identifier as text or use CSV."
        case .archiveFailed(let message):
            return "Could not create the Excel workbook: \(message)"
        }
    }
}

/// Type-preserving writer shared by scientific list exports.
///
/// Text beginning with an Excel formula prefix is apostrophe-protected in CSV/TSV.
/// XLSX uses explicit inline-string cells and therefore retains the unmodified text.
public enum ScientificTableWriter {
    public static let formulaTextPolicy = "CSV/TSV prefixes formula-like text with an apostrophe; XLSX stores all text as inline strings"
    public static let missingValuePolicy = "Missing values are empty fields/cells"
    public static let numericPolicy = "Typed integers and finite doubles are written without grouping or display rounding; textual identifiers remain text"

    public static func write(
        _ table: ScientificTableData,
        format: ScientificTableFormat,
        to url: URL,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws {
        _ = try writeWithReport(table, format: format, to: url, shouldCancel: shouldCancel)
    }

    @discardableResult
    public static func writeWithReport(
        _ table: ScientificTableData,
        format: ScientificTableFormat,
        to url: URL,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> ScientificTableWriteReport {
        try validateRectangle(table)
        if shouldCancel() { throw ScientificTableWriterError.cancelled }

        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).writer.tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let report: ScientificTableWriteReport
        switch format {
        case .csv:
            try writeDelimited(table, delimiter: ",", to: temporaryURL, shouldCancel: shouldCancel)
            report = .init()
        case .tsv:
            try writeDelimited(table, delimiter: "\t", to: temporaryURL, shouldCancel: shouldCancel)
            report = .init()
        case .json:
            try writeJSON(table, to: temporaryURL, shouldCancel: shouldCancel)
            report = .init()
        case .xlsx:
            report = try writeWorkbook(table, to: temporaryURL, shouldCancel: shouldCancel)
        }

        if shouldCancel() { throw ScientificTableWriterError.cancelled }
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        return report
    }

    private static func validateRectangle(_ table: ScientificTableData) throws {
        for (index, row) in table.rows.enumerated() where row.count != table.columns.count {
            throw ScientificTableWriterError.nonRectangular(
                row: index,
                expected: table.columns.count,
                actual: row.count
            )
        }
    }

    private static func writeDelimited(
        _ table: ScientificTableData,
        delimiter: Character,
        to url: URL,
        shouldCancel: @Sendable () -> Bool
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try appendDelimitedLine(table.columns.map { protectFormulaText($0.title) }, delimiter: delimiter, to: handle)
        for (rowIndex, row) in table.rows.enumerated() {
            if rowIndex.isMultiple(of: 128), shouldCancel() {
                throw ScientificTableWriterError.cancelled
            }
            let values = try row.enumerated().map { columnIndex, cell in
                try delimitedValue(cell, row: rowIndex, column: columnIndex)
            }
            try appendDelimitedLine(values, delimiter: delimiter, to: handle)
        }
        try handle.synchronize()
    }

    private static func appendDelimitedLine(
        _ values: [String],
        delimiter: Character,
        to handle: FileHandle
    ) throws {
        let line = values.map { escapeDelimited($0, delimiter: delimiter) }
            .joined(separator: String(delimiter)) + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func delimitedValue(_ cell: ScientificTableCell, row: Int, column: Int) throws -> String {
        switch cell {
        case .text(let value): return protectFormulaText(value)
        case .integer(let value): return String(value)
        case .number(let value):
            guard value.isFinite else {
                throw ScientificTableWriterError.nonFiniteNumber(row: row, column: column)
            }
            return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .empty: return ""
        }
    }

    private static func protectFormulaText(_ value: String) -> String {
        let dangerous = CharacterSet(charactersIn: "=+-@\t\r")
        let inspected = value.drop(while: { $0 == " " })
        guard let first = inspected.unicodeScalars.first, dangerous.contains(first) else { return value }
        return "'" + value
    }

    private static func escapeDelimited(_ value: String, delimiter: Character) -> String {
        guard value.contains(delimiter) || value.contains("\"") || value.contains("\r") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func writeJSON(
        _ table: ScientificTableData,
        to url: URL,
        shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw ScientificTableWriterError.cancelled }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(table)
        data.append(0x0A)
        if shouldCancel() { throw ScientificTableWriterError.cancelled }
        try data.write(to: url, options: .atomic)
    }

    private static func writeWorkbook(
        _ table: ScientificTableData,
        to url: URL,
        shouldCancel: @Sendable () -> Bool
    ) throws -> ScientificTableWriteReport {
        guard table.columns.count <= 16_384 else {
            throw ScientificTableWriterError.tooManyColumns(table.columns.count)
        }
        let totalRows = table.rows.count + 1
        guard totalRows <= 1_048_576 else {
            throw ScientificTableWriterError.tooManyRows(totalRows)
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-table-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let rels = directory.appendingPathComponent("_rels", isDirectory: true)
        let xl = directory.appendingPathComponent("xl", isDirectory: true)
        let worksheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        for subdirectory in [directory, rels, xl, worksheets, xlRels] {
            try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        }

        try contentTypesXML.write(to: directory.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRelationshipsXML.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookXML(sheetName: table.name).write(to: xl.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        try workbookRelationshipsXML.write(to: xlRels.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: xl.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
        try writeWorksheet(table, to: worksheets.appendingPathComponent("sheet1.xml"), shouldCancel: shouldCancel)
        if shouldCancel() { throw ScientificTableWriterError.cancelled }

        let archiveURL = directory.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).xlsx")
        let stderrURL = directory.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).zip-stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stderrHandle.close()
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: stderrURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        let archiveArguments = ["-q", "-r", archiveURL.path, "."]
        process.arguments = archiveArguments
        process.standardError = stderrHandle
        try process.run()
        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                process.waitUntilExit()
                throw ScientificTableWriterError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try stderrHandle.synchronize()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScientificTableWriterError.archiveFailed(message?.isEmpty == false ? message! : "zip exited with status \(process.terminationStatus)")
        }
        try fileManager.moveItem(at: archiveURL, to: url)
        return ScientificTableWriteReport(
            archiveToolPath: "/usr/bin/zip",
            archiveArgv: ["/usr/bin/zip"] + archiveArguments,
            archiveToolVersion: systemZipVersion()
        )
    }

    private static func writeWorksheet(
        _ table: ScientificTableData,
        to url: URL,
        shouldCancel: @Sendable () -> Bool
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let lastColumn = excelColumnName(max(1, table.columns.count))
        let widths = table.columns.enumerated().map { index, column -> String in
            let longestCell = table.rows.prefix(250).map { row -> Int in
                guard index < row.count else { return 0 }
                return displayLength(row[index])
            }.max() ?? 0
            let width = min(60, max(8, max(column.title.count, longestCell) + 2))
            return #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
        }.joined()
        try writeString("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:\(lastColumn)\(table.rows.count + 1)"/>
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <cols>\(widths)</cols><sheetData>
        """, to: handle)
        let headerCells = try table.columns.enumerated().map { index, column in
            try textCell(reference: "\(excelColumnName(index + 1))1", value: column.title, style: 1, row: 0, column: index)
        }.joined()
        try writeString("<row r=\"1\">\(headerCells)</row>\n", to: handle)
        for (rowIndex, row) in table.rows.enumerated() {
            if rowIndex.isMultiple(of: 128), shouldCancel() {
                throw ScientificTableWriterError.cancelled
            }
            let excelRow = rowIndex + 2
            let cells = try row.enumerated().map { columnIndex, cell in
                try worksheetCell(
                    cell,
                    reference: "\(excelColumnName(columnIndex + 1))\(excelRow)",
                    row: rowIndex,
                    column: columnIndex
                )
            }.joined()
            try writeString("<row r=\"\(excelRow)\">\(cells)</row>\n", to: handle)
        }
        try writeString("</sheetData><autoFilter ref=\"A1:\(lastColumn)\(table.rows.count + 1)\"/></worksheet>\n", to: handle)
        try handle.synchronize()
    }

    private static func worksheetCell(
        _ cell: ScientificTableCell,
        reference: String,
        row: Int,
        column: Int
    ) throws -> String {
        switch cell {
        case .text(let value):
            return try textCell(reference: reference, value: value, style: nil, row: row, column: column)
        case .integer(let value):
            guard abs(Double(value)) <= 9_007_199_254_740_991 else {
                throw ScientificTableWriterError.integerExceedsExcelPrecision(row: row, column: column, value: value)
            }
            return "<c r=\"\(reference)\"><v>\(value)</v></c>"
        case .number(let value):
            guard value.isFinite else {
                throw ScientificTableWriterError.nonFiniteNumber(row: row, column: column)
            }
            return "<c r=\"\(reference)\"><v>\(String(value))</v></c>"
        case .boolean(let value):
            return "<c r=\"\(reference)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
        case .empty:
            return "<c r=\"\(reference)\"/>"
        }
    }

    private static func textCell(
        reference: String,
        value: String,
        style: Int?,
        row: Int,
        column: Int
    ) throws -> String {
        guard value.utf16.count <= 32_767 else {
            throw ScientificTableWriterError.textTooLong(row: row, column: column)
        }
        guard isValidXML(value) else {
            throw ScientificTableWriterError.invalidXML(row: row, column: column)
        }
        let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
        return "<c r=\"\(reference)\" t=\"inlineStr\"\(styleAttribute)><is><t xml:space=\"preserve\">\(xlsxTextEscape(value))</t></is></c>"
    }

    private static func writeString(_ value: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(value.utf8))
    }

    private static func displayLength(_ cell: ScientificTableCell) -> Int {
        switch cell {
        case .text(let value): return min(60, value.count)
        case .integer(let value): return String(value).count
        case .number(let value): return String(value).count
        case .boolean: return 5
        case .empty: return 0
        }
    }

    private static func excelColumnName(_ oneBasedIndex: Int) -> String {
        var index = max(1, oneBasedIndex)
        var result = ""
        while index > 0 {
            index -= 1
            result = String(UnicodeScalar(65 + index % 26)!) + result
            index /= 26
        }
        return result
    }

    private static func isValidXML(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD
                || (0x20...0xD7FF).contains(scalar.value)
                || (0xE000...0xFFFD).contains(scalar.value)
                || (0x10000...0x10FFFF).contains(scalar.value)
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xlsxTextEscape(_ value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let protected: String
        if let regex = try? NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_") {
            protected = regex.stringByReplacingMatches(
                in: value, range: range, withTemplate: "_x005F_x$1_"
            )
        } else {
            protected = value
        }
        // XML's end-of-line normalization changes literal CR/CRLF. A character
        // reference preserves the original carriage return for workbook readers.
        return xmlEscape(protected).replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func xmlAttributeEscape(_ value: String) -> String {
        xmlEscape(value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
    }

    private static func workbookXML(sheetName: String) -> String {
        let boundedName = String(sheetName.prefix(31)).replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlAttributeEscape(boundedName.isEmpty ? "Table" : boundedName))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    }

    private static func systemZipVersion() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-v"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").first.map(String.init)
        } catch {
            return nil
        }
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
    """

    private static let rootRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """

    private static let workbookRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Helvetica"/></font><font><b/><sz val="11"/><name val="Helvetica"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" applyFont="1"/></cellXfs></styleSheet>
    """
}
