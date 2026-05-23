import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Exports the genotype bundle's matrix + annotation sidecar as a
/// standalone auditor-grade XLSX.
///
/// The workbook is intentionally lightweight (no embedded charts or
/// volatile formulas) so analysts can share a single self-describing
/// file. Sheets:
///
///   1. `Matrix` — sample × locus haplotype calls (H1/H2) colored using
///      the canonical Budde 2010 palette (M1-M7), matching what the
///      in-app inspector renders. ERR cells use the Lungfish danger
///      color. Empty/absent cells receive no fill.
///   2. `Legend` — palette swatches with display names so a reader who
///      has never opened the Lungfish app can decode the colors.
///   3. `Overrides` — the analyst-applied call overrides, if any.
///   4. `Audit Log` — the audit trail recorded in `annotations.json`.
///
/// This is provenance-`inspectOnly` (`cli.genotype` policy) — it never
/// modifies the bundle or its sidecar.
struct GenotypeExportXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-xlsx",
        abstract: "Export the genotype bundle's matrix and analyst annotations as an XLSX file."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundle)
        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)

        // Load the matrix when the bundle is complete; gracefully emit an
        // empty matrix when only the annotation sidecar is present (the
        // original CLI behavior). This keeps the command useful for
        // sharing the override log of a bundle without artifacts.
        let matrix: Matrix
        if let result = try? ONTGenotypeResultBundle.loadResult(from: bundleURL) {
            matrix = MatrixBuilder.build(from: result)
        } else {
            matrix = Matrix(loci: [], rows: [])
        }

        let overrides = sidecar.callOverrides.map { o in
            OverrideRow(
                sample: o.sample, locus: o.locus, slot: o.slot.rawValue,
                originalCall: o.originalCall, overrideCall: o.overrideCall,
                reason: o.reasonTag.rawValue, rationale: o.rationale,
                author: o.author, timestamp: o.timestamp
            )
        }
        let audit = sidecar.auditLog.map { e in
            AuditRow(
                action: e.action, sample: e.sample,
                locus: e.locus ?? "", slot: e.slot?.rawValue ?? "",
                before: e.before ?? "", after: e.after ?? "",
                author: e.author, timestamp: e.timestamp
            )
        }

        let outputURL = URL(fileURLWithPath: output)
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-genotype-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        try writeMinimalXLSX(
            to: outputURL,
            buildDir: buildDir,
            matrix: matrix,
            overrides: overrides,
            audit: audit
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "sampleCount": matrix.sampleRowCount,
            "locusCount": matrix.loci.count,
            "overrideCount": overrides.count,
            "auditEntryCount": audit.count
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(summaryData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - Matrix shape

    /// Per-sample haplotype call row in the rendered matrix.
    struct MatrixRow: Equatable {
        let sample: String
        /// Two cells per locus, in `matrix.loci` order: `[h1_0, h2_0, h1_1, h2_1, ...]`.
        let cells: [MatrixCell]
    }

    /// Single haplotype cell with the label and the styling token it
    /// resolved to. `tokenIndex` of 0 means absent (no fill); -1 means
    /// "ERR" and uses the danger fill.
    struct MatrixCell: Equatable {
        let label: String
        let tokenIndex: Int
        static let absent = MatrixCell(label: "", tokenIndex: 0)
        static func error(_ label: String) -> MatrixCell { .init(label: label, tokenIndex: -1) }
        static func haplotype(_ label: String, _ tokenIndex: Int) -> MatrixCell {
            .init(label: label, tokenIndex: tokenIndex)
        }
    }

    struct Matrix: Equatable {
        let loci: [String]
        let rows: [MatrixRow]
        var sampleRowCount: Int { rows.count }
    }

    enum MatrixBuilder {
        /// Builds the matrix from a bundle's haplotype analysis (preferred)
        /// or falls back to inferring per-sample haplotype tokens directly
        /// from the call list when no analysis sidecar exists.
        static func build(from result: ONTGenotypeResultBundleData) -> Matrix {
            if let analysis = result.haplotypeAnalysis {
                return buildFromAnalysis(analysis)
            }
            return buildFromCalls(samples: result.samples)
        }

        private static func buildFromAnalysis(
            _ analysis: GenotypeHaplotypeAnalysis
        ) -> Matrix {
            let loci = orderedLoci(analysis.samples.flatMap { $0.calls.map(\.locus) })
            let rows = analysis.samples.map { sample -> MatrixRow in
                let callsByLocus = Dictionary(uniqueKeysWithValues: sample.calls.map { ($0.locus, $0) })
                var cells: [MatrixCell] = []
                cells.reserveCapacity(loci.count * 2)
                for locus in loci {
                    guard let call = callsByLocus[locus] else {
                        cells.append(.absent)
                        cells.append(.absent)
                        continue
                    }
                    cells.append(cell(for: call.haplotype1))
                    cells.append(cell(for: call.haplotype2))
                }
                return MatrixRow(sample: sample.sample, cells: cells)
            }
            return Matrix(loci: loci, rows: rows)
        }

        private static func buildFromCalls(
            samples: [ONTGenotypeSampleResult]
        ) -> Matrix {
            // No haplotype analysis available — list the top genotype per
            // locus per sample. We still color each cell by the inferred
            // haplotype token (or M0 if none).
            let loci = orderedLoci(samples.flatMap { $0.calls.map(\.locusGroup) })
            let rows = samples.map { sample -> MatrixRow in
                var cellsByLocus: [String: ONTGenotypeCall] = [:]
                for call in sample.calls where cellsByLocus[call.locusGroup] == nil {
                    cellsByLocus[call.locusGroup] = call
                }
                var cells: [MatrixCell] = []
                cells.reserveCapacity(loci.count * 2)
                for locus in loci {
                    guard let call = cellsByLocus[locus] else {
                        cells.append(.absent)
                        cells.append(.absent)
                        continue
                    }
                    let tokens = call.haplotypeTokens
                    let h1 = tokens.first.map { cell(for: $0) } ?? .haplotype(call.genotype, 0)
                    let h2: MatrixCell
                    if tokens.count >= 2 {
                        h2 = cell(for: tokens[1])
                    } else {
                        h2 = .absent
                    }
                    cells.append(h1)
                    cells.append(h2)
                }
                return MatrixRow(sample: sample.sample, cells: cells)
            }
            return Matrix(loci: loci, rows: rows)
        }

        private static func cell(for name: String) -> MatrixCell {
            if name.isEmpty || name == "-" {
                return .absent
            }
            if name.hasPrefix("ERR:") {
                return .error(name)
            }
            let token = HaplotypeColorToken.assigned(forName: name)
            return .haplotype(name, token.canonicalIndex)
        }

        private static func orderedLoci(_ raw: [String]) -> [String] {
            var seen = Set<String>()
            var ordered: [String] = []
            for locus in raw where seen.insert(locus).inserted {
                ordered.append(locus)
            }
            return ordered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    // MARK: - Workbook output

    private struct OverrideRow {
        let sample, locus, slot, originalCall, overrideCall, reason, rationale, author, timestamp: String
    }

    private struct AuditRow {
        let action, sample, locus, slot, before, after, author, timestamp: String
    }

    private func writeMinimalXLSX(
        to outputURL: URL,
        buildDir: URL,
        matrix: Matrix,
        overrides: [OverrideRow],
        audit: [AuditRow]
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: buildDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        try Self.contentTypesXML.write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try Self.rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try Self.workbookXML.write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try Self.workbookRelsXML.write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try Self.stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makeMatrixSheet(matrix).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        try makeLegendSheet().write(to: buildDir.appendingPathComponent("xl/worksheets/sheet2.xml"), atomically: true, encoding: .utf8)
        try makeOverridesSheet(overrides).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet3.xml"), atomically: true, encoding: .utf8)
        try makeAuditSheet(audit).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet4.xml"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = buildDir
        zip.arguments = ["-qr", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            throw GenotypeExportXlsxError.zipFailed
        }
    }

    private func makeMatrixSheet(_ matrix: Matrix) -> String {
        var sheet = sheetHeader()
        // Two header rows: locus spans the H1/H2 columns; the second row
        // distinguishes H1 vs H2. Sample column is A in both rows.
        var locusHeader: [StyledCell] = [.header("Sample")]
        var slotHeader: [StyledCell] = [.header("")]
        for locus in matrix.loci {
            locusHeader.append(.header(locus))
            locusHeader.append(.header(""))
            slotHeader.append(.header("H1"))
            slotHeader.append(.header("H2"))
        }
        sheet += rowXML(index: 1, cells: locusHeader)
        sheet += rowXML(index: 2, cells: slotHeader)

        for (offset, row) in matrix.rows.enumerated() {
            var cells: [StyledCell] = [.body(row.sample)]
            for cell in row.cells {
                cells.append(styledCell(for: cell))
            }
            sheet += rowXML(index: offset + 3, cells: cells)
        }
        sheet += sheetFooter()
        return sheet
    }

    private func styledCell(for cell: MatrixCell) -> StyledCell {
        switch cell.tokenIndex {
        case -1:
            return .error(cell.label)
        case 0:
            return .body(cell.label)
        default:
            return .haplotype(cell.label, tokenIndex: cell.tokenIndex)
        }
    }

    private func makeLegendSheet() -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            .header("Token"),
            .header("Display Name"),
            .header("Hex"),
            .header("Notes")
        ])
        // M1-M7 swatches. Skip M0 since it's just "no fill" in the matrix.
        for index in 1...7 {
            let token = HaplotypeColorToken.canonicalPalette[index]
            sheet += rowXML(index: index + 1, cells: [
                .haplotype("M\(index)", tokenIndex: index),
                .body(token.displayName),
                .body(token.fillColor.hexString),
                .body("")
            ])
        }
        sheet += rowXML(index: 9, cells: [
            .error("ERR"),
            .body("Error / no call"),
            .body(Self.dangerHex),
            .body("ERR: NO HAP / ERR: TMH / ERR: TMG")
        ])
        sheet += rowXML(index: 10, cells: [
            .body("(blank)"),
            .body("Absent or unanalyzed"),
            .body(""),
            .body("Locus not observed or matched no haplotype definition")
        ])
        sheet += sheetFooter()
        return sheet
    }

    private func makeOverridesSheet(_ rows: [OverrideRow]) -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            .header("Sample"), .header("Locus"), .header("Slot"),
            .header("Original Call"), .header("Override Call"),
            .header("Reason"), .header("Rationale"),
            .header("Author"), .header("Timestamp")
        ])
        for (i, r) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                .body(r.sample), .body(r.locus), .body(r.slot),
                .body(r.originalCall), .body(r.overrideCall),
                .body(r.reason), .body(r.rationale),
                .body(r.author), .body(r.timestamp)
            ])
        }
        sheet += sheetFooter()
        return sheet
    }

    private func makeAuditSheet(_ rows: [AuditRow]) -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            .header("Action"), .header("Sample"), .header("Locus"),
            .header("Slot"), .header("Before"), .header("After"),
            .header("Author"), .header("Timestamp")
        ])
        for (i, r) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                .body(r.action), .body(r.sample), .body(r.locus),
                .body(r.slot), .body(r.before), .body(r.after),
                .body(r.author), .body(r.timestamp)
            ])
        }
        sheet += sheetFooter()
        return sheet
    }

    // MARK: - Cell styling

    /// A typed cell: header, body, error, or palette-colored haplotype.
    /// The associated `styleID` matches an `<xf>` in `Self.stylesXML`.
    private enum StyledCell {
        case header(String)
        case body(String)
        case error(String)
        case haplotype(String, tokenIndex: Int)

        var value: String {
            switch self {
            case .header(let v), .body(let v), .error(let v): return v
            case .haplotype(let v, _): return v
            }
        }

        var styleID: Int {
            switch self {
            case .header: return 1
            case .body: return 0
            case .error: return Self.errorStyleID
            case .haplotype(_, let tokenIndex):
                // Style IDs are laid out as:
                //   0 = body (default), 1 = header,
                //   2 = error,
                //   3..9 = M1..M7 fills.
                let clamped = max(1, min(7, tokenIndex))
                return Self.haplotypeStyleBase + (clamped - 1)
            }
        }

        static let errorStyleID = 2
        static let haplotypeStyleBase = 3
    }

    private func sheetHeader() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

        """
    }

    private func sheetFooter() -> String {
        "</sheetData></worksheet>"
    }

    private func rowXML(index: Int, cells: [StyledCell]) -> String {
        let cellXML = cells.enumerated().map { (col, cell) -> String in
            let ref = "\(columnLetter(col + 1))\(index)"
            let escaped = xmlEscape(cell.value)
            return #"<c r="\#(ref)" s="\#(cell.styleID)" t="inlineStr"><is><t>\#(escaped)</t></is></c>"#
        }.joined()
        return #"<row r="\#(index)">\#(cellXML)</row>"# + "\n"
    }

    private func columnLetter(_ oneBased: Int) -> String {
        var n = oneBased
        var result = ""
        while n > 0 {
            n -= 1
            let scalar = UnicodeScalar(65 + (n % 26))!
            result = String(scalar) + result
            n /= 26
        }
        return result
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Static workbook scaffolding

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/worksheets/sheet4.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Matrix" sheetId="1" r:id="rId1"/>
        <sheet name="Legend" sheetId="2" r:id="rId2"/>
        <sheet name="Overrides" sheetId="3" r:id="rId3"/>
        <sheet name="Audit Log" sheetId="4" r:id="rId4"/>
      </sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
      <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/>
      <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    /// Hex for the lungfishDanger NSColor (light-mode value) used to
    /// signal "ERR" cells. Mirrors `NSColor.lungfishDanger` defined in
    /// `Sources/LungfishApp/Views/Shared/LungfishColors.swift`.
    static let dangerHex = "#A65F3A"

    /// Styles.xml carries the canonical M1-M7 palette plus a danger fill
    /// for ERR cells and a bold header style. Each `<xf>` indexes into
    /// `<fills>`. The `<xf>` order matches `StyledCell.styleID`.
    static let stylesXML: String = {
        // Build fills array: [none, gray125, danger, M1..M7]
        var fills = [
            #"<fill><patternFill patternType="none"/></fill>"#,
            #"<fill><patternFill patternType="gray125"/></fill>"#,
        ]
        fills.append(solidFill(hex: dangerHex))
        for index in 1...7 {
            let token = HaplotypeColorToken.canonicalPalette[index]
            fills.append(solidFill(hex: token.fillColor.hexString))
        }
        let fillsXML = fills.joined()

        // Build fonts: [default body, bold header, then per-haplotype font color]
        // For each M1..M7 we use the canonical fontColor so light fills
        // (e.g. M5 yellow) get dark text and dark fills (e.g. M1 black)
        // get white text. Style 2 (error) uses white on the danger fill.
        var fonts = [
            #"<font><sz val="11"/><name val="Aptos"/></font>"#,
            #"<font><b/><sz val="11"/><name val="Aptos"/></font>"#,
            #"<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Aptos"/></font>"#,
        ]
        for index in 1...7 {
            let token = HaplotypeColorToken.canonicalPalette[index]
            fonts.append(#"<font><b/><sz val="11"/><color rgb="\#(argbHex(token.fontColor.hexString))"/><name val="Aptos"/></font>"#)
        }
        let fontsXML = fonts.joined()

        // Build cellXfs. Order matches StyledCell.styleID:
        //   0 = body (no fill, default font)
        //   1 = header (no fill, bold font)
        //   2 = error (danger fill, white bold font)
        //   3..9 = M1..M7 fills with the matching font color
        var xfs = [
            #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#,
            #"<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#,
            #"<xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>"#,
        ]
        // Fill IDs for M1..M7 start at 3 (after none, gray125, danger).
        // Font IDs for the M1..M7 colored fonts start at 3.
        for index in 1...7 {
            let fillID = 2 + index
            let fontID = 2 + index
            xfs.append(#"<xf numFmtId="0" fontId="\#(fontID)" fillId="\#(fillID)" borderId="0" xfId="0" applyFont="1" applyFill="1"/>"#)
        }
        let xfsXML = xfs.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="\(fonts.count)">\(fontsXML)</fonts>
          <fills count="\(fills.count)">\(fillsXML)</fills>
          <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="\(xfs.count)">\(xfsXML)</cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
    }()

    private static func solidFill(hex: String) -> String {
        #"<fill><patternFill patternType="solid"><fgColor rgb="\#(argbHex(hex))"/><bgColor indexed="64"/></patternFill></fill>"#
    }

    /// XLSX uses AARRGGBB ordering (alpha first). Strips any leading `#`.
    static func argbHex(_ hex: String) -> String {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return "FF" + trimmed.uppercased()
    }
}

enum GenotypeExportXlsxError: Error, LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed: return "Failed to zip the XLSX archive."
        }
    }
}
