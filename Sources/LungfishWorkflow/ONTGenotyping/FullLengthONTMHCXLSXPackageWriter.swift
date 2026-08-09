import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCXLSXPackageWriter {
    struct Sheet: Codable, Sendable, Equatable {
        let name: String
        let cells: [[FullLengthONTMHCWorkbookCell]]

        init(name: String, rows: [[String]]) {
            self.name = name
            cells = rows.map { row in row.map { FullLengthONTMHCWorkbookCell($0) } }
        }

        init(name: String, cells: [[FullLengthONTMHCWorkbookCell]]) {
            self.name = name
            self.cells = cells
        }
    }

    static func write(sheets: [Sheet], to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-full-length-mhc-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let rels = temp.appendingPathComponent("_rels", isDirectory: true)
        let xl = temp.appendingPathComponent("xl", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        let worksheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        for directory in [rels, xlRels, worksheets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try contentTypesXML(sheetCount: sheets.count).write(
            to: temp.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )
        try rootRelsXML.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookXML(sheetNames: sheets.map(\.name)).write(
            to: xl.appendingPathComponent("workbook.xml"),
            atomically: true,
            encoding: .utf8
        )
        try workbookRelsXML(sheetCount: sheets.count).write(
            to: xlRels.appendingPathComponent("workbook.xml.rels"),
            atomically: true,
            encoding: .utf8
        )
        try fullLengthONTMHCWorkbookStylesXML.write(
            to: xl.appendingPathComponent("styles.xml"),
            atomically: true,
            encoding: .utf8
        )
        for (index, sheet) in sheets.enumerated() {
            try worksheetXML(rows: sheet.cells).write(
                to: worksheets.appendingPathComponent("sheet\(index + 1).xml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-X", "-q", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        process.currentDirectoryURL = temp
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FullLengthONTMHCGenotypingError.reportFailed("zip exited with \(process.terminationStatus)")
        }
    }
}

private let rootRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"""

private func contentTypesXML(sheetCount: Int) -> String {
    let sheets = (1...sheetCount).map {
        "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    \(sheets)
    </Types>
    """
}

private func workbookXML(sheetNames: [String]) -> String {
    let sheets = sheetNames.enumerated().map { index, name in
        "<sheet name=\"\(ooxmlTextEncode(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
    \(sheets)
      </sheets>
    </workbook>
    """
}

private func workbookRelsXML(sheetCount: Int) -> String {
    let rels = (1...sheetCount).map {
        "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \(rels)
      <Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
}

private let fullLengthONTMHCWorkbookStylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="11"/><name val="Aptos"/></font>
    <font><b/><sz val="11"/><name val="Aptos"/></font>
  </fonts>
  <fills count="6">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.sharedNovel))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.singletonNovel))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.sharedExtension))"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="\(opaqueWorkbookARGB(FullLengthONTMHCWorkbookTintDefaults.singletonExtension))"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="6">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
"""

private func opaqueWorkbookARGB(_ rgb: String) -> String {
    "FF" + rgb
}

private func worksheetXML(rows: [[FullLengthONTMHCWorkbookCell]]) -> String {
    let rowCount = max(rows.count, 1)
    let columnCount = max(rows.map(\.count).max() ?? 1, 1)
    let dimension = "A1:\(xlsxColumn(columnCount))\(rowCount)"
    let widths = (0..<columnCount).map { columnIndex -> String in
        let length = rows.compactMap { row -> Int? in
            guard row.indices.contains(columnIndex) else { return nil }
            return workbookCellDisplayText(row[columnIndex]).count
        }.max() ?? 0
        let width = min(48, max(8, length + 2))
        return "<col min=\"\(columnIndex + 1)\" max=\"\(columnIndex + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
    }.joined()
    let body = rows.enumerated().map { rowIndex, row in
        let cells = row.enumerated().map { columnIndex, cell in
            let ref = "\(xlsxColumn(columnIndex + 1))\(rowIndex + 1)"
            let style = workbookCellStyle(cell, isHeader: rowIndex == 0).map { " s=\"\($0)\"" } ?? ""
            switch cell.value {
            case .text(let value):
                return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(ooxmlTextEncode(value))</t></is></c>"
            case .integer(let value):
                return "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
            case .decimal(let value):
                return "<c r=\"\(ref)\"\(style)><v>\(workbookDecimal(value))</v></c>"
            case .blank:
                return "<c r=\"\(ref)\"\(style)/>"
            }
        }.joined()
        return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
    }.joined(separator: "\n")
    let filter = rows.isEmpty ? "" : "<autoFilter ref=\"A1:\(xlsxColumn(columnCount))\(rowCount)\"/>"
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <dimension ref="\(dimension)"/>
      <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
      <cols>\(widths)</cols>
      <sheetData>
    \(body)
      </sheetData>
      \(filter)
    </worksheet>
    """
}

private func workbookCellStyle(_ cell: FullLengthONTMHCWorkbookCell, isHeader: Bool) -> Int? {
    if isHeader { return 1 }
    switch cell.tint {
    case .sharedNovel: return 2
    case .singletonNovel: return 3
    case .sharedExtension: return 4
    case .singletonExtension: return 5
    case nil: return nil
    }
}

private func workbookCellDisplayText(_ cell: FullLengthONTMHCWorkbookCell) -> String {
    switch cell.value {
    case .text(let value): value
    case .integer(let value): String(value)
    case .decimal(let value): workbookDecimal(value)
    case .blank: ""
    }
}

private func workbookDecimal(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func xlsxColumn(_ oneBasedIndex: Int) -> String {
    var value = oneBasedIndex
    var result = ""
    while value > 0 {
        value -= 1
        let scalar = UnicodeScalar(65 + (value % 26))!
        result.insert(Character(scalar), at: result.startIndex)
        value /= 26
    }
    return result
}

private func ooxmlTextEncode(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var encoded = ""
    encoded.reserveCapacity(value.utf8.count)
    for index in scalars.indices {
        let scalar = scalars[index]
        if scalar == "_", isLiteralOOXMLEscapeToken(at: index, in: scalars) {
            encoded += "_x005F_"
            continue
        }
        guard isLegalXML10Scalar(scalar.value) else {
            encoded += String(format: "_x%04X_", scalar.value)
            continue
        }
        switch scalar {
        case "&": encoded += "&amp;"
        case "<": encoded += "&lt;"
        case ">": encoded += "&gt;"
        case "\"": encoded += "&quot;"
        case "'": encoded += "&apos;"
        default: encoded.unicodeScalars.append(scalar)
        }
    }
    return encoded
}

private func isLiteralOOXMLEscapeToken(
    at index: Int,
    in scalars: [Unicode.Scalar]
) -> Bool {
    guard index + 6 < scalars.count,
          scalars[index + 1] == "x" || scalars[index + 1] == "X",
          scalars[index + 6] == "_" else {
        return false
    }
    return scalars[(index + 2)...(index + 5)].allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: true
        default: false
        }
    }
}

private func isLegalXML10Scalar(_ value: UInt32) -> Bool {
    value == 0x9
        || value == 0xA
        || value == 0xD
        || (0x20...0xD7FF).contains(value)
        || (0xE000...0xFFFD).contains(value)
        || (0x10000...0x10FFFF).contains(value)
}
