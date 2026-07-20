import Foundation
import LungfishCore
import LungfishIO

/// Shared XLSX writer for genotype bundle exports.
///
/// Both `genotype export-xlsx` (full-bundle matrix) and the unified
/// `genotype export` (matrix or analyst-visible view projection) render
/// through this type, so the workbook scaffolding, the Budde 2010 palette
/// styling, and the ERR/danger fill live in exactly one place.
///
/// The workbook is intentionally lightweight (no embedded charts or
/// volatile formulas). Sheets vary by entry point:
///
///   * ``writeMatrix(to:matrix:overrides:audit:annotations:)`` writes the
///     auditor workbook (`Matrix`, `Legend`, `Overrides`, `Audit Log`), plus
///     a `Matrix Annotations` sheet when native matrix annotations are present.
///   * ``writeViewProjection(_:to:annotations:)`` writes a `View` sheet that
///     reproduces the GUI viewport's visible sample columns, rows, and
///     per-cell / per-row colors, plus a Matrix Annotations sheet when
///     native matrix annotations are present.
struct GenotypeXlsxWorkbookWriter: Sendable {
    init() {}

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
        static func build(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar? = nil
        ) -> Matrix {
            if let analysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
                for: result,
                sidecar: sidecar
            ) {
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

    // MARK: - Auditor input rows

    /// Analyst-applied call override row. Owned by the writer so both
    /// entry points pass the same shape.
    struct OverrideRow {
        let sample, locus, slot, originalCall, overrideCall, reason, rationale, author, timestamp: String
        init(
            sample: String, locus: String, slot: String, originalCall: String,
            overrideCall: String, reason: String, rationale: String, author: String, timestamp: String
        ) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.originalCall = originalCall
            self.overrideCall = overrideCall
            self.reason = reason
            self.rationale = rationale
            self.author = author
            self.timestamp = timestamp
        }
    }

    /// Audit-trail row mirrored from `annotations.json`.
    struct AuditRow {
        let action, sample, locus, slot, before, after, author, timestamp: String
        init(
            action: String, sample: String, locus: String, slot: String,
            before: String, after: String, author: String, timestamp: String
        ) {
            self.action = action
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.before = before
            self.after = after
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct MatrixAnnotationRow {
        let recordType: String
        let targetKind: String
        let sample: String
        let locus: String
        let genotype: String
        let fillColor: String
        let textColor: String
        let borderColor: String
        let isBold: String
        let boldOverride: String
        let isItalic: String
        let italicOverride: String
        let comment: String
        let author: String
        let timestamp: String
    }

    // MARK: - Projection helpers

    /// The sample columns the projection resolves to, in display order.
    /// Exposed for tests and for the command to log the resolved view.
    static func resolvedSampleColumns(for projection: GenotypeViewProjection) -> [String] {
        projection.sampleColumns
    }

    // MARK: - Full-bundle matrix workbook

    /// Writes the four-sheet auditor workbook (matrix + legend + overrides
    /// + audit log). This is the behavior `export-xlsx` has always had; it
    /// now delegates here.
    func writeMatrix(
        to outputURL: URL,
        matrix: Matrix,
        overrides: [OverrideRow],
        audit: [AuditRow],
        annotations sidecar: GenotypeAnnotationSidecar? = nil
    ) throws {
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-genotype-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        try fm.createDirectory(at: buildDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        let annotationRows = matrixAnnotationRows(from: sidecar)
        let hasAnnotations = !annotationRows.isEmpty

        try Self.matrixContentTypesXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try Self.rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try Self.matrixWorkbookXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try Self.matrixWorkbookRelsXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try Self.stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makeMatrixSheet(matrix).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        try makeLegendSheet().write(to: buildDir.appendingPathComponent("xl/worksheets/sheet2.xml"), atomically: true, encoding: .utf8)
        try makeOverridesSheet(overrides).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet3.xml"), atomically: true, encoding: .utf8)
        try makeAuditSheet(audit).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet4.xml"), atomically: true, encoding: .utf8)
        if hasAnnotations {
            try makeMatrixAnnotationsSheet(annotationRows).write(
                to: buildDir.appendingPathComponent("xl/worksheets/sheet5.xml"),
                atomically: true,
                encoding: .utf8
            )
        }

        try zipBuildDir(buildDir, to: outputURL)
    }

    // MARK: - View-projection workbook

    /// Writes a single-sheet workbook reproducing the GUI viewport's
    /// visible sample columns, rows, and colors. The projection is rendered
    /// directly (NOT funneled through `MatrixBuilder`) so the export shows
    /// exactly what the analyst saw, including ad-hoc row/cell highlights
    /// that the canonical palette would not reproduce.
    func writeViewProjection(
        _ projection: GenotypeViewProjection,
        to outputURL: URL,
        annotations sidecar: GenotypeAnnotationSidecar? = nil
    ) throws {
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-genotype-view-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        try fm.createDirectory(at: buildDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        // The view sheet draws ad-hoc colors from the projection, so it
        // carries its own dynamic style table built from the hex strings
        // present in the projection (plus the canonical body/header styles).
        let palette = ProjectionPalette(projection: projection)

        let annotationRows = matrixAnnotationRows(from: sidecar)
        let hasAnnotations = !annotationRows.isEmpty

        try Self.projectionContentTypesXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try Self.rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try Self.projectionWorkbookXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try Self.projectionWorkbookRelsXML(includeAnnotations: hasAnnotations)
            .write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try palette.stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makeProjectionSheet(projection, palette: palette).write(
            to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"),
            atomically: true,
            encoding: .utf8
        )
        if hasAnnotations {
            try makeMatrixAnnotationsSheet(annotationRows).write(
                to: buildDir.appendingPathComponent("xl/worksheets/sheet2.xml"),
                atomically: true,
                encoding: .utf8
            )
        }

        try zipBuildDir(buildDir, to: outputURL)
    }

    /// Renders the projection's rows into delimited text (CSV/TSV). The
    /// header row is `Locus`, `Row` + the visible sample columns; each body
    /// row carries stable locus identity before the visible cell values.
    static func renderDelimited(
        _ projection: GenotypeViewProjection,
        separator: String
    ) -> String {
        var lines: [String] = []
        lines.append(delimitedRow(["Locus", "Row"] + projection.sampleColumns, separator: separator))
        for row in projection.rows {
            lines.append(delimitedRow([row.locus ?? "", row.label] + row.cells, separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the full-bundle matrix into delimited text (CSV/TSV) for the
    /// no-projection path of `genotype export --format {csv,tsv}`.
    static func renderDelimited(_ matrix: Matrix, separator: String) -> String {
        var header = ["Sample"]
        for locus in matrix.loci {
            header.append("\(locus) H1")
            header.append("\(locus) H2")
        }
        var lines = [delimitedRow(header, separator: separator)]
        for row in matrix.rows {
            lines.append(delimitedRow([row.sample] + row.cells.map(\.label), separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func delimitedRow(_ fields: [String], separator: String) -> String {
        fields.map { field in
            let needsQuoting = field.contains(separator)
                || field.contains("\"")
                || field.contains("\n")
                || field.contains("\r")
            if needsQuoting {
                return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return field
        }.joined(separator: separator)
    }

    // MARK: - Sheets

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

    private func makeMatrixAnnotationsSheet(_ rows: [MatrixAnnotationRow]) -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            .header("Record Type"),
            .header("Target Kind"),
            .header("Sample"),
            .header("Locus"),
            .header("Genotype"),
            .header("Fill Color"),
            .header("Text Color"),
            .header("Border Color"),
            .header("Is Bold"),
            .header("Bold Override"),
            .header("Is Italic"),
            .header("Italic Override"),
            .header("Comment"),
            .header("Author"),
            .header("Timestamp"),
        ])
        for (i, row) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                .body(row.recordType),
                .body(row.targetKind),
                .body(row.sample),
                .body(row.locus),
                .body(row.genotype),
                .body(row.fillColor),
                .body(row.textColor),
                .body(row.borderColor),
                .body(row.isBold),
                .body(row.boldOverride),
                .body(row.isItalic),
                .body(row.italicOverride),
                .body(row.comment),
                .body(row.author),
                .body(row.timestamp),
            ])
        }
        sheet += sheetFooter()
        return sheet
    }

    private func matrixAnnotationRows(from sidecar: GenotypeAnnotationSidecar?) -> [MatrixAnnotationRow] {
        guard let sidecar else { return [] }
        var rows: [MatrixAnnotationRow] = []
        rows.reserveCapacity(sidecar.matrixStyles.count + sidecar.matrixComments.count)
        for style in sidecar.matrixStyles {
            let target = matrixTargetFields(style.target)
            rows.append(MatrixAnnotationRow(
                recordType: "style",
                targetKind: target.kind,
                sample: target.sample,
                locus: target.locus,
                genotype: target.genotype,
                fillColor: style.style.fillColor ?? "",
                textColor: style.style.textColor ?? "",
                borderColor: style.style.borderColor ?? "",
                isBold: style.style.isBold ? "true" : "false",
                boldOverride: style.style.boldOverride.map { $0 ? "true" : "false" } ?? "",
                isItalic: style.style.isItalic ? "true" : "false",
                italicOverride: style.style.italicOverride.map { $0 ? "true" : "false" } ?? "",
                comment: "",
                author: style.author,
                timestamp: style.timestamp
            ))
        }
        for comment in sidecar.matrixComments {
            let target = matrixTargetFields(comment.target)
            rows.append(MatrixAnnotationRow(
                recordType: "comment",
                targetKind: target.kind,
                sample: target.sample,
                locus: target.locus,
                genotype: target.genotype,
                fillColor: "",
                textColor: "",
                borderColor: "",
                isBold: "",
                boldOverride: "",
                isItalic: "",
                italicOverride: "",
                comment: comment.body,
                author: comment.author,
                timestamp: comment.timestamp
            ))
        }
        return rows
    }

    private func matrixTargetFields(
        _ target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> (kind: String, sample: String, locus: String, genotype: String) {
        switch target {
        case let .row(locus, genotype, _):
            return ("row", "", locus, genotype)
        case let .column(sample):
            return ("column", sample, "", "")
        case let .cell(locus, genotype, sample, _):
            return ("cell", sample, locus, genotype)
        }
    }

    private func makeProjectionSheet(
        _ projection: GenotypeViewProjection,
        palette: ProjectionPalette
    ) -> String {
        var sheet = sheetHeader()
        // Header: stable row identity columns + one column per visible sample.
        var header: [StyledCell] = [.header("Locus"), .header("Row")]
        for sample in projection.sampleColumns {
            header.append(.header(sample))
        }
        sheet += rowXML(index: 1, cells: header)

        for (offset, row) in projection.rows.enumerated() {
            var cells: [StyledCell] = [.body(row.locus ?? ""), projectionLabelCell(row, palette: palette)]
            for (column, _) in projection.sampleColumns.enumerated() {
                let value = column < row.cells.count ? row.cells[column] : ""
                let hex = projectionCellHex(row, column: column)
                cells.append(palette.styledCell(value: value, hex: hex))
            }
            sheet += rowXML(index: offset + 2, cells: cells)
        }
        sheet += sheetFooter()
        return sheet
    }

    private func projectionLabelCell(
        _ row: GenotypeViewProjectionRow,
        palette: ProjectionPalette
    ) -> StyledCell {
        if let rowHex = row.rowColorHex {
            return palette.styledCell(value: row.label, hex: rowHex, bold: true)
        }
        return .header(row.label)
    }

    private func projectionCellHex(_ row: GenotypeViewProjectionRow, column: Int) -> String? {
        if let cellColors = row.cellColorsHex, column < cellColors.count, let hex = cellColors[column] {
            return hex
        }
        return row.rowColorHex
    }

    // MARK: - Zip

    private func zipBuildDir(_ buildDir: URL, to outputURL: URL) throws {
        let fm = FileManager.default
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
            throw GenotypeXlsxWorkbookWriterError.zipFailed
        }
    }

    // MARK: - Cell styling

    /// A typed cell: header, body, error, or palette-colored haplotype.
    /// The associated `styleID` matches an `<xf>` in `Self.stylesXML`.
    enum StyledCell {
        case header(String)
        case body(String)
        case error(String)
        case haplotype(String, tokenIndex: Int)
        /// A view-projection cell whose fill resolves to an explicit style
        /// index in the projection palette's dynamic style table.
        case dynamic(String, styleIndex: Int)

        var value: String {
            switch self {
            case .header(let v), .body(let v), .error(let v): return v
            case .haplotype(let v, _): return v
            case .dynamic(let v, _): return v
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
                // The canonical Budde 2010 palette (indices 1-7) renders
                // exactly. Extended palette indices (8..63) — used for
                // Rhesus haplotypes that hash beyond the canonical seven —
                // cycle back into M1..M7 in the workbook export. This
                // matches the inspector's "best-effort" colour preview
                // for off-canonical names. Long-term, expanding the
                // stylesXML to all 63 assignable tokens would let Rhesus
                // workbooks preserve every distinct token.
                let resolved = tokenIndex <= 7 ? max(1, tokenIndex) : ((tokenIndex - 1) % 7) + 1
                return Self.haplotypeStyleBase + (resolved - 1)
            case .dynamic(_, let styleIndex):
                return styleIndex
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

    private static func matrixContentTypesXML(includeAnnotations: Bool) -> String {
        let annotationOverride = includeAnnotations
            ? #"  <Override PartName="/xl/worksheets/sheet5.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# + "\n"
            : ""
        return """
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
        \(annotationOverride)</Types>
        """
    }

    private static func projectionContentTypesXML(includeAnnotations: Bool) -> String {
        let annotationOverride = includeAnnotations
            ? #"  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        \(annotationOverride)</Types>
        """
    }

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static func matrixWorkbookXML(includeAnnotations: Bool) -> String {
        let annotationSheet = includeAnnotations
            ? #"    <sheet name="Matrix Annotations" sheetId="5" r:id="rId6"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Matrix" sheetId="1" r:id="rId1"/>
            <sheet name="Legend" sheetId="2" r:id="rId2"/>
            <sheet name="Overrides" sheetId="3" r:id="rId3"/>
            <sheet name="Audit Log" sheetId="4" r:id="rId4"/>
        \(annotationSheet)  </sheets>
        </workbook>
        """
    }

    private static func projectionWorkbookXML(includeAnnotations: Bool) -> String {
        let annotationSheet = includeAnnotations
            ? #"    <sheet name="Matrix Annotations" sheetId="2" r:id="rId2"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="View" sheetId="1" r:id="rId1"/>
        \(annotationSheet)  </sheets>
        </workbook>
        """
    }

    private static func matrixWorkbookRelsXML(includeAnnotations: Bool) -> String {
        let annotationRelationship = includeAnnotations
            ? #"  <Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet5.xml"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
          <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/>
          <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \(annotationRelationship)</Relationships>
        """
    }

    private static func projectionWorkbookRelsXML(includeAnnotations: Bool) -> String {
        let annotationRelationship = includeAnnotations
            ? #"  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        \(annotationRelationship)  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

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

    static func solidFill(hex: String) -> String {
        #"<fill><patternFill patternType="solid"><fgColor rgb="\#(argbHex(hex))"/><bgColor indexed="64"/></patternFill></fill>"#
    }

    /// XLSX uses AARRGGBB ordering (alpha first). Strips any leading `#`.
    static func argbHex(_ hex: String) -> String {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return "FF" + trimmed.uppercased()
    }
}

// MARK: - Projection palette

/// A dynamic style table built from the hex colors present in a view
/// projection. Style indices 0 (body) and 1 (header) are fixed; any unique
/// fill hex in the projection gets its own appended `<xf>` so the view sheet
/// reproduces the analyst's exact colors.
private struct ProjectionPalette {
    /// Maps an uppercased `RRGGBB` (no `#`) to its `<xf>` index.
    private var styleIndexByHex: [String: Int] = [:]
    private var orderedHex: [String] = []

    init(projection: GenotypeViewProjection) {
        var seen = Set<String>()
        func register(_ hex: String?) {
            guard let hex, let key = Self.normalize(hex), seen.insert(key).inserted else { return }
            orderedHex.append(key)
        }
        for row in projection.rows {
            register(row.rowColorHex)
            for hex in row.cellColorsHex ?? [] {
                register(hex)
            }
        }
        // Styles 0/1 are body/header; dynamic fills start at index 2.
        for (offset, hex) in orderedHex.enumerated() {
            styleIndexByHex[hex] = 2 + offset
        }
    }

    func styledCell(
        value: String,
        hex: String?,
        bold: Bool = false
    ) -> GenotypeXlsxWorkbookWriter.StyledCell {
        guard let hex, let key = Self.normalize(hex), let index = styleIndexByHex[key] else {
            return bold ? .header(value) : .body(value)
        }
        return .dynamic(value, styleIndex: index)
    }

    private static func normalize(_ hex: String) -> String? {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6 else { return nil }
        return trimmed.uppercased()
    }

    var stylesXML: String {
        // Fills: [none, gray125, <one solid per registered hex>].
        var fills = [
            #"<fill><patternFill patternType="none"/></fill>"#,
            #"<fill><patternFill patternType="gray125"/></fill>"#,
        ]
        for hex in orderedHex {
            fills.append(GenotypeXlsxWorkbookWriter.solidFill(hex: hex))
        }
        let fillsXML = fills.joined()

        let fonts = [
            #"<font><sz val="11"/><name val="Aptos"/></font>"#,
            #"<font><b/><sz val="11"/><name val="Aptos"/></font>"#,
        ]
        let fontsXML = fonts.joined()

        // cellXfs index layout: 0 = body, 1 = header (bold), 2.. = dynamic
        // fills (bold, fill index offset by the two leading non-color fills).
        var xfs = [
            #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#,
            #"<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#,
        ]
        for offset in orderedHex.indices {
            let fillID = 2 + offset
            xfs.append(#"<xf numFmtId="0" fontId="1" fillId="\#(fillID)" borderId="0" xfId="0" applyFont="1" applyFill="1"/>"#)
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
    }
}

enum GenotypeXlsxWorkbookWriterError: Error, LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed: return "Failed to zip the XLSX archive."
        }
    }
}
