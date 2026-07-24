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
        let action, target, disposition, validationStatus, validationReason: String
        let sample, locus, slot, before, after, author, timestamp: String
        init(
            action: String, sample: String, locus: String, slot: String,
            before: String, after: String, author: String, timestamp: String,
            target: String = "", disposition: String = "",
            validationStatus: String = "", validationReason: String = ""
        ) {
            self.action = action
            self.target = target
            self.disposition = disposition
            self.validationStatus = validationStatus
            self.validationReason = validationReason
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
        let stableClusterID: String
        let disposition: String
        let validationStatus: String
        let validationReason: String
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

        let fullMatrixReviewValidation:
            (GenotypeAnnotationSidecar.MatrixReviewAnnotation) -> (status: String, reason: String) =
                { _ in
                    (
                        "unapplied",
                        "The full Matrix worksheet is sample-by-haplotype and does not carry exact genotype-row identity."
                    )
                }
        let annotationRows = matrixAnnotationRows(
            from: sidecar,
            reviewValidation: fullMatrixReviewValidation
        )
        let exportAudit = audit + matrixReviewAuditRows(
            from: sidecar,
            reviewValidation: fullMatrixReviewValidation
        )
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
        try makeAuditSheet(exportAudit).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet4.xml"), atomically: true, encoding: .utf8)
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
        let semantics = ProjectionSemantics(projection: projection, sidecar: sidecar)
        let palette = ProjectionPalette(projection: projection, reviews: semantics.validReviews)

        let annotationRows = matrixAnnotationRows(
            from: sidecar,
            reviewValidation: { review in
                semantics.validationByTarget[review.target]
                    ?? ("invalid", "No exact projection cell matches the review target.")
            }
        )
        let hasAnnotations = !annotationRows.isEmpty
        let reviewAuditRows = matrixReviewAuditRows(
            from: sidecar,
            reviewValidation: { review in
                semantics.validationByTarget[review.target]
                    ?? ("invalid", "No exact projection cell matches the review target.")
            }
        )
        let hasAudit = !(sidecar?.auditLog.isEmpty ?? true) || !reviewAuditRows.isEmpty

        try Self.projectionContentTypesXML(
            includeAnnotations: hasAnnotations,
            includeAudit: hasAudit,
            includeComments: !semantics.notes.isEmpty
        )
            .write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try Self.rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try Self.projectionWorkbookXML(includeAnnotations: hasAnnotations, includeAudit: hasAudit)
            .write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try Self.projectionWorkbookRelsXML(includeAnnotations: hasAnnotations, includeAudit: hasAudit)
            .write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try palette.stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makeProjectionSheet(
            projection,
            palette: palette,
            semantics: semantics,
            includeLegacyDrawing: !semantics.notes.isEmpty
        ).write(
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
        if hasAudit, let sidecar {
            let auditRows = sidecar.auditLog.map {
                AuditRow(
                    action: $0.action,
                    sample: $0.sample,
                    locus: $0.locus ?? "",
                    slot: $0.slot?.rawValue ?? "",
                    before: $0.before ?? "",
                    after: $0.after ?? "",
                    author: $0.author,
                    timestamp: $0.timestamp
                )
            } + reviewAuditRows
            try makeAuditSheet(auditRows).write(
                to: buildDir.appendingPathComponent("xl/worksheets/sheet3.xml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if !semantics.notes.isEmpty {
            try fm.createDirectory(
                at: buildDir.appendingPathComponent("xl/worksheets/_rels"),
                withIntermediateDirectories: true
            )
            try fm.createDirectory(
                at: buildDir.appendingPathComponent("xl/drawings"),
                withIntermediateDirectories: true
            )
            try makeCommentsXML(semantics.notes).write(
                to: buildDir.appendingPathComponent("xl/comments1.xml"),
                atomically: true,
                encoding: .utf8
            )
            try makeCommentsVML(semantics.notes).write(
                to: buildDir.appendingPathComponent("xl/drawings/commentsDrawing1.vml"),
                atomically: true,
                encoding: .utf8
            )
            try Self.commentsSheetRelationshipsXML.write(
                to: buildDir.appendingPathComponent("xl/worksheets/_rels/sheet1.xml.rels"),
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
            .header("Action"), .header("Target"), .header("Disposition"),
            .header("Validation Status"), .header("Validation Reason"),
            .header("Sample"), .header("Locus"),
            .header("Slot"), .header("Before"), .header("After"),
            .header("Author"), .header("Timestamp")
        ])
        for (i, r) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                .body(r.action), .body(r.target), .body(r.disposition),
                .body(r.validationStatus), .body(r.validationReason),
                .body(r.sample), .body(r.locus),
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
            .header("Stable Cluster ID"),
            .header("Disposition"),
            .header("Validation Status"),
            .header("Validation Reason"),
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
                .body(row.stableClusterID),
                .body(row.disposition),
                .body(row.validationStatus),
                .body(row.validationReason),
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

    private func matrixAnnotationRows(
        from sidecar: GenotypeAnnotationSidecar?,
        reviewValidation: (
            (GenotypeAnnotationSidecar.MatrixReviewAnnotation) -> (status: String, reason: String)
        )? = nil
    ) -> [MatrixAnnotationRow] {
        guard let sidecar else { return [] }
        var rows: [MatrixAnnotationRow] = []
        rows.reserveCapacity(
            sidecar.matrixStyles.count
                + sidecar.resolvedMatrixComments.count
                + sidecar.matrixReviews.count
        )
        for style in sidecar.matrixStyles {
            let target = matrixTargetFields(style.target)
            rows.append(MatrixAnnotationRow(
                recordType: "style",
                targetKind: target.kind,
                sample: target.sample,
                locus: target.locus,
                genotype: target.genotype,
                stableClusterID: target.stableClusterID,
                disposition: "",
                validationStatus: "not-applicable",
                validationReason: "",
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
        for comment in sidecar.resolvedMatrixComments.values.sorted(by: {
            $0.target.stableAuditDescription < $1.target.stableAuditDescription
        }) {
            let target = matrixTargetFields(comment.target)
            rows.append(MatrixAnnotationRow(
                recordType: "comment",
                targetKind: target.kind,
                sample: target.sample,
                locus: target.locus,
                genotype: target.genotype,
                stableClusterID: target.stableClusterID,
                disposition: "",
                validationStatus: "not-applicable",
                validationReason: "",
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
        for review in sidecar.matrixReviews {
            let target = matrixTargetFields(review.target)
            let validation: (status: String, reason: String) = reviewValidation?(review)
                ?? (
                    status: "unapplied",
                    reason: "No workbook validation context was supplied."
                )
            rows.append(MatrixAnnotationRow(
                recordType: "review",
                targetKind: target.kind,
                sample: target.sample,
                locus: target.locus,
                genotype: target.genotype,
                stableClusterID: target.stableClusterID,
                disposition: review.disposition.rawValue,
                validationStatus: validation.status,
                validationReason: validation.reason,
                fillColor: "",
                textColor: "",
                borderColor: "",
                isBold: "",
                boldOverride: "",
                isItalic: "",
                italicOverride: "",
                comment: "",
                author: review.author,
                timestamp: review.timestamp
            ))
        }
        return rows
    }

    private func matrixReviewAuditRows(
        from sidecar: GenotypeAnnotationSidecar?,
        reviewValidation: (
            (GenotypeAnnotationSidecar.MatrixReviewAnnotation) -> (status: String, reason: String)
        )
    ) -> [AuditRow] {
        guard let sidecar else { return [] }
        return sidecar.matrixReviews.map { review in
            let target = matrixTargetFields(review.target)
            let validation = reviewValidation(review)
            return AuditRow(
                action: "matrixReviewExportValidation",
                sample: target.sample,
                locus: target.locus,
                slot: "",
                before: "",
                after: "",
                author: review.author,
                timestamp: review.timestamp,
                target: review.target.stableAuditDescription,
                disposition: review.disposition.rawValue,
                validationStatus: validation.status,
                validationReason: validation.reason
            )
        }
    }

    private func matrixTargetFields(
        _ target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> (kind: String, sample: String, locus: String, genotype: String, stableClusterID: String) {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            return ("row", "", locus, genotype, stableClusterID ?? "")
        case let .column(sample):
            return ("column", sample, "", "", "")
        case let .cell(locus, genotype, sample, stableClusterID):
            return ("cell", sample, locus, genotype, stableClusterID ?? "")
        }
    }

    private func makeProjectionSheet(
        _ projection: GenotypeViewProjection,
        palette: ProjectionPalette,
        semantics: ProjectionSemantics,
        includeLegacyDrawing: Bool
    ) -> String {
        var sheet = sheetHeader()
        // Header: stable row identity columns + one column per visible sample.
        var header: [StyledCell] = [
            .header("Locus"),
            .header("Row"),
            .header("Stable Cluster ID"),
        ]
        for sample in projection.sampleColumns {
            header.append(.header(sample))
        }
        sheet += rowXML(index: 1, cells: header)

        for (offset, row) in projection.rows.enumerated() {
            var cells: [StyledCell] = [
                .body(row.locus ?? ""),
                projectionLabelCell(row, palette: palette),
                .body(row.stableClusterID ?? ""),
            ]
            for (column, _) in projection.sampleColumns.enumerated() {
                let value = column < row.cells.count ? row.cells[column] : ""
                let hex = projectionCellHex(row, column: column)
                let review = semantics.validReviews[
                    ProjectionCoordinate(row: offset, sampleColumn: column)
                ]
                let displayValue: String
                if review == .falsePositive {
                    displayValue = "[\(value)]"
                } else if review == .falseNegative,
                          value.trimmingCharacters(in: .whitespacesAndNewlines) == "-" {
                    displayValue = ""
                } else {
                    displayValue = value
                }
                cells.append(palette.styledCell(value: displayValue, hex: hex, review: review))
            }
            sheet += rowXML(index: offset + 2, cells: cells)
        }
        sheet += sheetFooter(includeLegacyDrawing: includeLegacyDrawing)
        return sheet
    }

    fileprivate struct ProjectionCoordinate: Hashable {
        let row: Int
        let sampleColumn: Int
    }

    private struct ProjectionNoteSection {
        let label: String
        let body: String
        let author: String
        let timestamp: String

        var renderedText: String {
            """
            \(label)
            Body: \(body)
            Author: \(author)
            Timestamp: \(timestamp)
            """
        }
    }

    private struct NativeNote {
        let reference: String
        let zeroBasedRow: Int
        let zeroBasedColumn: Int
        let sections: [ProjectionNoteSection]

        var body: String {
            sections.map(\.renderedText).joined(separator: "\n\n")
        }
    }

    private struct ProjectionSemantics {
        let validReviews: [
            ProjectionCoordinate: GenotypeAnnotationSidecar.MatrixReviewDisposition
        ]
        let validationByTarget: [
            GenotypeAnnotationSidecar.MatrixTarget: (status: String, reason: String)
        ]
        let notes: [NativeNote]

        init(
            projection: GenotypeViewProjection,
            sidecar: GenotypeAnnotationSidecar?
        ) {
            guard let sidecar else {
                validReviews = [:]
                validationByTarget = [:]
                notes = []
                return
            }

            var reviews: [
                ProjectionCoordinate: GenotypeAnnotationSidecar.MatrixReviewDisposition
            ] = [:]
            var validation: [
                GenotypeAnnotationSidecar.MatrixTarget: (status: String, reason: String)
            ] = [:]
            let reviewCountByTarget = Dictionary(
                grouping: sidecar.matrixReviews,
                by: \.target
            ).mapValues(\.count)
            for review in sidecar.matrixReviews {
                if reviewCountByTarget[review.target, default: 0] > 1 {
                    validation[review.target] = (
                        "invalid",
                        "Conflicting duplicate review records target the same projection cell."
                    )
                    continue
                }
                guard case let .cell(locus, genotype, sample, stableClusterID) = review.target else {
                    validation[review.target] = (
                        "invalid",
                        "Matrix reviews require an exact cell target."
                    )
                    continue
                }
                let matchingRows = projection.rows.indices.filter { index in
                    let row = projection.rows[index]
                    return row.locus == locus
                        && row.label == genotype
                        && row.stableClusterID == stableClusterID
                }
                guard matchingRows.count == 1,
                      let sampleColumn = projection.sampleColumns.firstIndex(of: sample),
                      projection.sampleColumns.lastIndex(of: sample) == sampleColumn else {
                    validation[review.target] = (
                        "invalid",
                        "No unique projection cell matches the exact locus, genotype, sample, and stable cluster ID."
                    )
                    continue
                }
                let rowIndex = matchingRows[0]
                let rawValue = sampleColumn < projection.rows[rowIndex].cells.count
                    ? projection.rows[rowIndex].cells[sampleColumn]
                    : ""
                let evidence = Self.numericEvidence(rawValue)
                switch review.disposition {
                case .falsePositive:
                    guard let evidence, evidence > 0 else {
                        validation[review.target] = (
                            "invalid",
                            "False-positive reviews require passedUniqueReads > 0."
                        )
                        continue
                    }
                case .falseNegative:
                    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty
                            || trimmed == "-"
                            || evidence == 0 else {
                        validation[review.target] = (
                            "invalid",
                            "False-negative reviews require zero or absent passedUniqueReads."
                        )
                        continue
                    }
                }
                reviews[ProjectionCoordinate(row: rowIndex, sampleColumn: sampleColumn)] =
                    review.disposition
                validation[review.target] = ("valid", "")
            }

            let comments = sidecar.resolvedMatrixComments
            var rowComments: [Int: GenotypeAnnotationSidecar.MatrixComment] = [:]
            var columnComments: [Int: GenotypeAnnotationSidecar.MatrixComment] = [:]
            var cellComments: [
                ProjectionCoordinate: GenotypeAnnotationSidecar.MatrixComment
            ] = [:]
            for comment in comments.values {
                switch comment.target {
                case let .row(locus, genotype, stableClusterID):
                    let matches = projection.rows.indices.filter {
                        projection.rows[$0].locus == locus
                            && projection.rows[$0].label == genotype
                            && projection.rows[$0].stableClusterID == stableClusterID
                    }
                    if matches.count == 1 {
                        rowComments[matches[0]] = comment
                    }
                case let .column(sample):
                    if let index = projection.sampleColumns.firstIndex(of: sample),
                       projection.sampleColumns.lastIndex(of: sample) == index {
                        columnComments[index] = comment
                    }
                case let .cell(locus, genotype, sample, stableClusterID):
                    let matches = projection.rows.indices.filter {
                        projection.rows[$0].locus == locus
                            && projection.rows[$0].label == genotype
                            && projection.rows[$0].stableClusterID == stableClusterID
                    }
                    if matches.count == 1,
                       let sampleIndex = projection.sampleColumns.firstIndex(of: sample),
                       projection.sampleColumns.lastIndex(of: sample) == sampleIndex {
                        cellComments[
                            ProjectionCoordinate(row: matches[0], sampleColumn: sampleIndex)
                        ] = comment
                    }
                }
            }

            func section(
                _ label: String,
                _ comment: GenotypeAnnotationSidecar.MatrixComment
            ) -> ProjectionNoteSection {
                ProjectionNoteSection(
                    label: label,
                    body: comment.body,
                    author: comment.author,
                    timestamp: comment.timestamp
                )
            }

            var noteByReference: [String: NativeNote] = [:]
            for (rowIndex, comment) in rowComments {
                let workbookRow = rowIndex + 2
                let ref = "B\(workbookRow)"
                noteByReference[ref] = NativeNote(
                    reference: ref,
                    zeroBasedRow: workbookRow - 1,
                    zeroBasedColumn: 1,
                    sections: [section("Allele Row", comment)]
                )
            }
            for (sampleIndex, comment) in columnComments {
                let workbookColumn = sampleIndex + 4
                let ref = "\(Self.columnName(workbookColumn))1"
                noteByReference[ref] = NativeNote(
                    reference: ref,
                    zeroBasedRow: 0,
                    zeroBasedColumn: workbookColumn - 1,
                    sections: [section("Sample Column", comment)]
                )
            }
            for rowIndex in projection.rows.indices {
                for sampleIndex in projection.sampleColumns.indices {
                    let coordinate = ProjectionCoordinate(
                        row: rowIndex,
                        sampleColumn: sampleIndex
                    )
                    var sections: [ProjectionNoteSection] = []
                    if let comment = rowComments[rowIndex] {
                        sections.append(section("Allele Row", comment))
                    }
                    if let comment = columnComments[sampleIndex] {
                        sections.append(section("Sample Column", comment))
                    }
                    if let comment = cellComments[coordinate] {
                        sections.append(section("Cell", comment))
                    }
                    guard !sections.isEmpty else { continue }
                    let workbookRow = rowIndex + 2
                    let workbookColumn = sampleIndex + 4
                    let ref = "\(Self.columnName(workbookColumn))\(workbookRow)"
                    noteByReference[ref] = NativeNote(
                        reference: ref,
                        zeroBasedRow: workbookRow - 1,
                        zeroBasedColumn: workbookColumn - 1,
                        sections: sections
                    )
                }
            }

            validReviews = reviews
            validationByTarget = validation
            notes = noteByReference.values.sorted {
                if $0.zeroBasedRow != $1.zeroBasedRow {
                    return $0.zeroBasedRow < $1.zeroBasedRow
                }
                return $0.zeroBasedColumn < $1.zeroBasedColumn
            }
        }

        private static func numericEvidence(_ value: String) -> Int? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let unwrapped: String
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                unwrapped = String(trimmed.dropFirst().dropLast())
            } else {
                unwrapped = trimmed
            }
            return Int(unwrapped)
        }

        private static func columnName(_ oneBased: Int) -> String {
            var value = oneBased
            var result = ""
            while value > 0 {
                value -= 1
                result = String(UnicodeScalar(65 + (value % 26))!) + result
                value /= 26
            }
            return result
        }
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
        let publicationURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: publicationURL) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = buildDir
        zip.arguments = ["-qr", publicationURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            throw GenotypeXlsxWorkbookWriterError.zipFailed
        }
        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: publicationURL)
        } else {
            try fm.moveItem(at: publicationURL, to: outputURL)
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
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>

        """
    }

    private func sheetFooter(includeLegacyDrawing: Bool = false) -> String {
        let legacyDrawing = includeLegacyDrawing ? #"<legacyDrawing r:id="rId2"/>"# : ""
        return "</sheetData>\(legacyDrawing)</worksheet>"
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

    private func makeCommentsXML(_ notes: [NativeNote]) -> String {
        var authors: [String] = []
        var authorIndex: [String: Int] = [:]
        for note in notes {
            for section in note.sections where authorIndex[section.author] == nil {
                authorIndex[section.author] = authors.count
                authors.append(section.author)
            }
        }
        let authorsXML = authors
            .map { "<author>\(xmlEscape($0))</author>" }
            .joined()
        let commentsXML = notes.map { note in
            let author = note.sections.first?.author ?? "Lungfish"
            let id = authorIndex[author] ?? 0
            return #"<comment ref="\#(note.reference)" authorId="\#(id)"><text><t xml:space="preserve">\#(xmlEscape(note.body))</t></text></comment>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <comments xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <authors>\(authorsXML)</authors>
          <commentList>\(commentsXML)</commentList>
        </comments>
        """
    }

    private func makeCommentsVML(_ notes: [NativeNote]) -> String {
        let shapes = notes.enumerated().map { offset, note in
            let shapeID = 1025 + offset
            return """
              <v:shape id="_x0000_s\(shapeID)" type="#_x0000_t202" style="position:absolute;margin-left:80pt;margin-top:5pt;width:160pt;height:80pt;z-index:\(offset + 1);visibility:hidden" fillcolor="#ffffe1" o:insetmode="auto">
                <v:fill color2="#ffffe1"/>
                <v:shadow on="t" color="black" obscured="t"/>
                <v:path o:connecttype="none"/>
                <v:textbox style="mso-direction-alt:auto"><div style="text-align:left"/></v:textbox>
                <x:ClientData ObjectType="Note">
                  <x:MoveWithCells/><x:SizeWithCells/>
                  <x:Anchor>\(note.zeroBasedColumn), 15, \(note.zeroBasedRow), 2, \(note.zeroBasedColumn + 3), 15, \(note.zeroBasedRow + 5), 4</x:Anchor>
                  <x:AutoFill>False</x:AutoFill>
                  <x:Row>\(note.zeroBasedRow)</x:Row>
                  <x:Column>\(note.zeroBasedColumn)</x:Column>
                </x:ClientData>
              </v:shape>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel">
          <o:shapelayout v:ext="edit"><o:idmap v:ext="edit" data="1"/></o:shapelayout>
          <v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe">
            <v:stroke joinstyle="miter"/><v:path gradientshapeok="t" o:connecttype="rect"/>
          </v:shapetype>
        \(shapes)</xml>
        """
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

    private static func projectionContentTypesXML(
        includeAnnotations: Bool,
        includeAudit: Bool,
        includeComments: Bool
    ) -> String {
        let annotationOverride = includeAnnotations
            ? #"  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# + "\n"
            : ""
        let auditOverride = includeAudit
            ? #"  <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# + "\n"
            : ""
        let commentTypes = includeComments
            ? """
              <Default Extension="vml" ContentType="application/vnd.openxmlformats-officedocument.vmlDrawing"/>
              <Override PartName="/xl/comments1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"/>

            """
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        \(annotationOverride)\(auditOverride)\(commentTypes)</Types>
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

    private static func projectionWorkbookXML(includeAnnotations: Bool, includeAudit: Bool) -> String {
        let annotationSheet = includeAnnotations
            ? #"    <sheet name="Matrix Annotations" sheetId="2" r:id="rId2"/>"# + "\n"
            : ""
        let auditSheet = includeAudit
            ? #"    <sheet name="Audit Log" sheetId="3" r:id="rId3"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="View" sheetId="1" r:id="rId1"/>
        \(annotationSheet)\(auditSheet)  </sheets>
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

    private static func projectionWorkbookRelsXML(
        includeAnnotations: Bool,
        includeAudit: Bool
    ) -> String {
        let annotationRelationship = includeAnnotations
            ? #"  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>"# + "\n"
            : ""
        let auditRelationship = includeAudit
            ? #"  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>"# + "\n"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        \(annotationRelationship)\(auditRelationship)  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private static let commentsSheetRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="../comments1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../drawings/commentsDrawing1.vml"/>
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
    private struct StyleKey: Hashable {
        let hex: String?
        let bold: Bool
        let review: GenotypeAnnotationSidecar.MatrixReviewDisposition?
    }

    private var styleIndexByKey: [StyleKey: Int] = [:]
    private var orderedKeys: [StyleKey] = []
    private var fillIDByHex: [String: Int] = [:]
    private var orderedHex: [String] = []

    init(
        projection: GenotypeViewProjection,
        reviews: [
            GenotypeXlsxWorkbookWriter.ProjectionCoordinate:
                GenotypeAnnotationSidecar.MatrixReviewDisposition
        ]
    ) {
        var seenHex = Set<String>()
        func registerHex(_ hex: String?) {
            guard let hex, let normalized = Self.normalize(hex),
                  seenHex.insert(normalized).inserted else { return }
            orderedHex.append(normalized)
        }
        for row in projection.rows {
            registerHex(row.rowColorHex)
            for hex in row.cellColorsHex ?? [] {
                registerHex(hex)
            }
        }
        for (offset, hex) in orderedHex.enumerated() {
            fillIDByHex[hex] = 2 + offset
        }

        var seenKeys = Set<StyleKey>()
        func register(_ key: StyleKey) {
            guard seenKeys.insert(key).inserted else { return }
            orderedKeys.append(key)
        }
        for row in projection.rows {
            register(StyleKey(hex: Self.normalize(row.rowColorHex), bold: true, review: nil))
        }
        for rowIndex in projection.rows.indices {
            let row = projection.rows[rowIndex]
            for sampleIndex in projection.sampleColumns.indices {
                let explicitHex = row.cellColorsHex.flatMap {
                    sampleIndex < $0.count ? $0[sampleIndex] : nil
                }
                let hex = Self.normalize(explicitHex ?? row.rowColorHex)
                let review = reviews[
                    .init(row: rowIndex, sampleColumn: sampleIndex)
                ]
                register(StyleKey(hex: hex, bold: hex != nil, review: review))
            }
        }
        for (offset, key) in orderedKeys.enumerated() {
            styleIndexByKey[key] = 2 + offset
        }
    }

    func styledCell(
        value: String,
        hex: String?,
        bold: Bool = false,
        review: GenotypeAnnotationSidecar.MatrixReviewDisposition? = nil
    ) -> GenotypeXlsxWorkbookWriter.StyledCell {
        let key = StyleKey(hex: Self.normalize(hex), bold: bold || hex != nil, review: review)
        guard let index = styleIndexByKey[key] else {
            return bold ? .header(value) : .body(value)
        }
        return .dynamic(value, styleIndex: index)
    }

    private static func normalize(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, trimmed.allSatisfy(\.isHexDigit) else { return nil }
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
            #"<font><i/><sz val="11"/><color rgb="FF767676"/><name val="Aptos"/></font>"#,
        ]
        let fontsXML = fonts.joined()

        let borders = [
            #"<border><left/><right/><top/><bottom/><diagonal/></border>"#,
            #"<border><left style="thick"><color rgb="FF000000"/></left><right style="thick"><color rgb="FF000000"/></right><top style="thick"><color rgb="FF000000"/></top><bottom style="thick"><color rgb="FF000000"/></bottom><diagonal/></border>"#,
        ]
        let bordersXML = borders.joined()

        // cellXfs index layout: 0 = body, 1 = header, 2.. = deduplicated
        // combinations of viewport fill and semantic review presentation.
        var xfs = [
            #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#,
            #"<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>"#,
        ]
        for key in orderedKeys {
            let fillID = key.hex.flatMap { fillIDByHex[$0] } ?? 0
            let fontID: Int
            let borderID: Int
            switch key.review {
            case .falsePositive:
                fontID = 2
                borderID = 0
            case .falseNegative:
                fontID = key.bold ? 1 : 0
                borderID = 1
            case nil:
                fontID = key.bold ? 1 : 0
                borderID = 0
            }
            let applyFill = fillID == 0 ? "" : #" applyFill="1""#
            let applyFont = fontID == 0 ? "" : #" applyFont="1""#
            let applyBorder = borderID == 0 ? "" : #" applyBorder="1""#
            xfs.append(
                #"<xf numFmtId="0" fontId="\#(fontID)" fillId="\#(fillID)" borderId="\#(borderID)" xfId="0"\#(applyFont)\#(applyFill)\#(applyBorder)/>"#
            )
        }
        let xfsXML = xfs.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="\(fonts.count)">\(fontsXML)</fonts>
          <fills count="\(fills.count)">\(fillsXML)</fills>
          <borders count="\(borders.count)">\(bordersXML)</borders>
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
