import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct GenotypeViewportExportSnapshot: Equatable {
    let bundleURL: URL
    let analysisName: String
    let lens: String
    let filters: [String: String]
    let sampleNames: [String]
    let rows: [GenotypeViewportExportRow]
    let provenanceInputURLs: [URL]
    /// Optional annotation sidecar to surface in additional worksheets.
    /// When non-nil, the export adds an Overrides sheet and an Audit Log
    /// sheet so consumers reading the workbook see what the analyst has
    /// changed without needing the bundle's annotations.json.
    let sidecar: GenotypeAnnotationSidecarSnapshot?

    init(
        bundleURL: URL,
        analysisName: String,
        lens: String,
        filters: [String: String],
        sampleNames: [String],
        rows: [GenotypeViewportExportRow],
        provenanceInputURLs: [URL] = [],
        sidecar: GenotypeAnnotationSidecarSnapshot? = nil
    ) {
        self.bundleURL = bundleURL
        self.analysisName = analysisName
        self.lens = lens
        self.filters = filters
        self.sampleNames = sampleNames
        self.rows = rows
        self.provenanceInputURLs = provenanceInputURLs
        self.sidecar = sidecar
    }
}

struct GenotypeAnnotationSidecarSnapshot: Equatable {
    let overrides: [GenotypeAnnotationOverrideEntry]
    let auditEntries: [GenotypeAnnotationAuditEntry]
}

struct GenotypeAnnotationOverrideEntry: Equatable {
    let sample: String
    let locus: String
    let slot: String
    let originalCall: String
    let overrideCall: String
    let reasonTag: String
    let rationale: String
    let author: String
    let timestamp: String
}

struct GenotypeAnnotationAuditEntry: Equatable {
    let action: String
    let sample: String
    let locus: String
    let slot: String
    let before: String
    let after: String
    let author: String
    let timestamp: String
}

struct GenotypeViewportExportRow: Equatable {
    let genotype: String
    let locus: String
    let sampleCount: Int
    let totalUniqueReads: Int
    let sampleReads: [String: Int]
    let rowStyle: GenotypeResultHighlightStyle
    let cellStyles: [String: GenotypeResultHighlightStyle]
}

struct GenotypeViewportExcelExportResult: Equatable {
    let packageURL: URL
    let workbookURL: URL
    let provenanceURL: URL
}

struct GenotypeViewportExcelExportService {
    func export(
        snapshot: GenotypeViewportExportSnapshot,
        to packageURL: URL
    ) throws -> GenotypeViewportExcelExportResult {
        let startedAt = Date()
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) {
            try fm.removeItem(at: packageURL)
        }
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let workbookURL = packageURL.appendingPathComponent("genotype-view.xlsx")
        try writeWorkbook(snapshot: snapshot, to: workbookURL, packageURL: packageURL)

        let sourceManifestURL = snapshot.bundleURL.appendingPathComponent("genotype-result.json")
        let sourceInputURL = fm.fileExists(atPath: sourceManifestURL.path) ? sourceManifestURL : snapshot.bundleURL
        var resolvedOptions = snapshot.filters.mapValues { ParameterValue.string($0) }
        resolvedOptions["visibleSampleIds"] = .array(snapshot.sampleNames.map { .string($0) })
        resolvedOptions["visibleSampleCount"] = .integer(snapshot.sampleNames.count)

        var builder = try ProvenanceRunBuilder(
            workflowName: "Genotype viewport Excel export",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv([
            "lungfish-gui",
            "export-genotype-viewport",
            "--bundle", snapshot.bundleURL.path,
            "--lens", snapshot.lens,
            "--output", workbookURL.path,
        ])
        .options(
            explicit: [
                "lens": .string(snapshot.lens),
                "rowCount": .integer(snapshot.rows.count),
                "sampleColumnCount": .integer(snapshot.sampleNames.count),
            ],
            defaults: [
                "format": .string("xlsx"),
            ],
            resolved: resolvedOptions
        )
        .input(sourceInputURL, format: .json, role: .input)
        .output(workbookURL, format: .unknown, role: .report)
        .runtime(ProvenanceRuntimeIdentity())
        let annotationURL = snapshot.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        if snapshot.sidecar != nil, fm.fileExists(atPath: annotationURL.path) {
            builder = try builder.input(annotationURL, format: .json, role: .input)
        }
        for inputURL in snapshot.provenanceInputURLs where fm.fileExists(atPath: inputURL.path) {
            builder = try builder.input(inputURL, format: .json, role: .input)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: Date()
        )
        let provenanceURL = try ProvenanceWriter(signingProvider: nil).write(envelope, to: packageURL)
        return GenotypeViewportExcelExportResult(
            packageURL: packageURL,
            workbookURL: workbookURL,
            provenanceURL: provenanceURL
        )
    }

    private func writeWorkbook(
        snapshot: GenotypeViewportExportSnapshot,
        to workbookURL: URL,
        packageURL: URL
    ) throws {
        let fm = FileManager.default
        let buildURL = packageURL.appendingPathComponent(".xlsx-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: buildURL) }
        try fm.createDirectory(at: buildURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: buildURL.appendingPathComponent("_rels", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildURL.appendingPathComponent("docProps", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildURL.appendingPathComponent("xl/_rels", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildURL.appendingPathComponent("xl/worksheets", isDirectory: true), withIntermediateDirectories: true)

        let styleBook = XLSXStyleBook(rows: snapshot.rows, sampleNames: snapshot.sampleNames)
        let includesSidecarSheets = snapshot.sidecar != nil
        try write(Self.contentTypesXML(includesSidecarSheets: includesSidecarSheets),
                  to: buildURL.appendingPathComponent("[Content_Types].xml"))
        try write(Self.relationshipsXML, to: buildURL.appendingPathComponent("_rels/.rels"))
        try write(Self.appXML, to: buildURL.appendingPathComponent("docProps/app.xml"))
        try write(coreXML(title: snapshot.analysisName), to: buildURL.appendingPathComponent("docProps/core.xml"))
        try write(Self.workbookXML(includesSidecarSheets: includesSidecarSheets),
                  to: buildURL.appendingPathComponent("xl/workbook.xml"))
        try write(Self.workbookRelationshipsXML(includesSidecarSheets: includesSidecarSheets),
                  to: buildURL.appendingPathComponent("xl/_rels/workbook.xml.rels"))
        try write(styleBook.stylesXML, to: buildURL.appendingPathComponent("xl/styles.xml"))
        try write(matrixWorksheetXML(snapshot: snapshot, styleBook: styleBook),
                  to: buildURL.appendingPathComponent("xl/worksheets/sheet1.xml"))
        try write(filtersWorksheetXML(snapshot: snapshot),
                  to: buildURL.appendingPathComponent("xl/worksheets/sheet2.xml"))
        if let sidecar = snapshot.sidecar {
            try write(overridesWorksheetXML(snapshot: snapshot, overrides: sidecar.overrides),
                      to: buildURL.appendingPathComponent("xl/worksheets/sheet3.xml"))
            try write(auditWorksheetXML(snapshot: snapshot, entries: sidecar.auditEntries),
                      to: buildURL.appendingPathComponent("xl/worksheets/sheet4.xml"))
        }
        try zipXLSX(buildURL: buildURL, workbookURL: workbookURL)
    }

    private func overridesWorksheetXML(
        snapshot: GenotypeViewportExportSnapshot,
        overrides: [GenotypeAnnotationOverrideEntry]
    ) -> String {
        var rows = [
            xlsxRow(index: 1, values: [
                .string("Sample", style: 1),
                .string("Locus", style: 1),
                .string("Slot", style: 1),
                .string("Original Call", style: 1),
                .string("Override Call", style: 1),
                .string("Reason", style: 1),
                .string("Rationale", style: 1),
                .string("Author", style: 1),
                .string("Timestamp", style: 1),
            ])
        ]
        for (offset, entry) in overrides.enumerated() {
            rows.append(xlsxRow(index: offset + 2, values: [
                .string(entry.sample, style: 0),
                .string(entry.locus, style: 0),
                .string(entry.slot, style: 0),
                .string(entry.originalCall, style: 0),
                .string(entry.overrideCall, style: 0),
                .string(entry.reasonTag, style: 0),
                .string(entry.rationale, style: 0),
                .string(entry.author, style: 0),
                .string(entry.timestamp, style: 0),
            ]))
        }
        return worksheetXML(rows: rows)
    }

    private func auditWorksheetXML(
        snapshot: GenotypeViewportExportSnapshot,
        entries: [GenotypeAnnotationAuditEntry]
    ) -> String {
        var rows = [
            xlsxRow(index: 1, values: [
                .string("Action", style: 1),
                .string("Sample", style: 1),
                .string("Locus", style: 1),
                .string("Slot", style: 1),
                .string("Before", style: 1),
                .string("After", style: 1),
                .string("Author", style: 1),
                .string("Timestamp", style: 1),
            ])
        ]
        for (offset, entry) in entries.enumerated() {
            rows.append(xlsxRow(index: offset + 2, values: [
                .string(entry.action, style: 0),
                .string(entry.sample, style: 0),
                .string(entry.locus, style: 0),
                .string(entry.slot, style: 0),
                .string(entry.before, style: 0),
                .string(entry.after, style: 0),
                .string(entry.author, style: 0),
                .string(entry.timestamp, style: 0),
            ]))
        }
        return worksheetXML(rows: rows)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url)
    }

    private func zipXLSX(buildURL: URL, workbookURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = buildURL
        process.arguments = ["-qr", workbookURL.path, "."]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GenotypeViewportExcelExportError.zipFailed(stderr)
        }
    }

    private func matrixWorksheetXML(
        snapshot: GenotypeViewportExportSnapshot,
        styleBook: XLSXStyleBook
    ) -> String {
        let headers = ["Genotype", "Locus", "Samples", "Unique Reads"] + snapshot.sampleNames
        var rows: [String] = [xlsxRow(index: 1, values: headers.map { .string($0, style: 1) })]
        for (offset, row) in snapshot.rows.enumerated() {
            var cells: [XLSXCellValue] = [
                .string(row.genotype, style: styleBook.styleID(for: row.rowStyle)),
                .string(row.locus, style: styleBook.styleID(for: row.rowStyle)),
                .number(row.sampleCount, style: styleBook.styleID(for: row.rowStyle)),
                .number(row.totalUniqueReads, style: styleBook.styleID(for: row.rowStyle)),
            ]
            for sample in snapshot.sampleNames {
                let style = row.cellStyles[sample] ?? row.rowStyle
                if let reads = row.sampleReads[sample] {
                    cells.append(.number(reads, style: styleBook.styleID(for: style)))
                } else {
                    cells.append(.string("", style: styleBook.styleID(for: style)))
                }
            }
            rows.append(xlsxRow(index: offset + 2, values: cells))
        }
        return worksheetXML(rows: rows)
    }

    private func filtersWorksheetXML(snapshot: GenotypeViewportExportSnapshot) -> String {
        var rows = [
            xlsxRow(index: 1, values: [.string("Property", style: 1), .string("Value", style: 1)]),
            xlsxRow(index: 2, values: [.string("Analysis", style: 0), .string(snapshot.analysisName, style: 0)]),
            xlsxRow(index: 3, values: [.string("Lens", style: 0), .string(snapshot.lens, style: 0)]),
            xlsxRow(index: 4, values: [.string("Source Bundle", style: 0), .string(snapshot.bundleURL.path, style: 0)]),
        ]
        for (offset, item) in snapshot.filters.sorted(by: { $0.key < $1.key }).enumerated() {
            rows.append(xlsxRow(index: offset + 5, values: [.string(item.key, style: 0), .string(item.value, style: 0)]))
        }
        return worksheetXML(rows: rows)
    }

    private func worksheetXML(rows: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <sheetData>
        \(rows.joined(separator: "\n"))
          </sheetData>
        </worksheet>
        """
    }

    private func xlsxRow(index: Int, values: [XLSXCellValue]) -> String {
        let cells = values.enumerated().map { column, value in
            value.xml(reference: "\(columnName(column + 1))\(index)")
        }.joined()
        return #"    <row r="\#(index)">\#(cells)</row>"#
    }

    private func columnName(_ oneBasedIndex: Int) -> String {
        var index = oneBasedIndex
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    private func coreXML(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xmlEscape(title)) genotype viewport export</dc:title>
          <dc:creator>Lungfish Genome Explorer</dc:creator>
          <cp:lastModifiedBy>Lungfish Genome Explorer</cp:lastModifiedBy>
        </cp:coreProperties>
        """
    }

    private static func contentTypesXML(includesSidecarSheets: Bool) -> String {
        var sheets = [
            #"      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#,
            #"      <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#,
        ]
        if includesSidecarSheets {
            sheets.append(#"      <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#)
            sheets.append(#"      <Override PartName="/xl/worksheets/sheet4.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(sheets.joined(separator: "\n"))
        </Types>
        """
    }

    private static let relationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static func workbookXML(includesSidecarSheets: Bool) -> String {
        var sheets = [
            #"    <sheet name="Visible Matrix" sheetId="1" r:id="rId1"/>"#,
            #"    <sheet name="Filters" sheetId="2" r:id="rId2"/>"#,
        ]
        if includesSidecarSheets {
            sheets.append(#"    <sheet name="Overrides" sheetId="3" r:id="rId4"/>"#)
            sheets.append(#"    <sheet name="Audit Log" sheetId="4" r:id="rId5"/>"#)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
        \(sheets.joined(separator: "\n"))
          </sheets>
        </workbook>
        """
    }

    private static func workbookRelationshipsXML(includesSidecarSheets: Bool) -> String {
        var rels = [
            #"  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>"#,
            #"  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>"#,
            #"  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#,
        ]
        if includesSidecarSheets {
            rels.append(#"  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>"#)
            rels.append(#"  <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/>"#)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(rels.joined(separator: "\n"))
        </Relationships>
        """
    }

    private static let appXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
      <Application>Lungfish Genome Explorer</Application>
    </Properties>
    """
}

private enum XLSXCellValue {
    case string(String, style: Int)
    case number(Int, style: Int)

    func xml(reference: String) -> String {
        switch self {
        case .string(let value, let style):
            return #"<c r="\#(reference)" s="\#(style)" t="inlineStr"><is><t>\#(xmlEscape(value))</t></is></c>"#
        case .number(let value, let style):
            return #"<c r="\#(reference)" s="\#(style)"><v>\#(value)</v></c>"#
        }
    }
}

private struct XLSXStyleBook {
    private let styleIDs: [GenotypeResultHighlightStyle: Int]
    let stylesXML: String

    init(rows: [GenotypeViewportExportRow], sampleNames: [String]) {
        var styles: [GenotypeResultHighlightStyle] = [.default]
        for row in rows {
            if !styles.contains(row.rowStyle) {
                styles.append(row.rowStyle)
            }
            for sample in sampleNames {
                if let style = row.cellStyles[sample], !styles.contains(style) {
                    styles.append(style)
                }
            }
        }
        var ids: [GenotypeResultHighlightStyle: Int] = [:]
        for (index, style) in styles.enumerated() {
            ids[style] = index == 0 ? 0 : index + 1
        }
        styleIDs = ids
        stylesXML = Self.makeStylesXML(styles: styles)
    }

    func styleID(for style: GenotypeResultHighlightStyle) -> Int {
        styleIDs[style] ?? 0
    }

    private static func makeStylesXML(styles: [GenotypeResultHighlightStyle]) -> String {
        let fillColors = uniqueColors(styles.compactMap(\.fillColor))
        let borderColors = uniqueColors(styles.compactMap(\.borderColor))
        let fillID: [AnnotationColor: Int] = Dictionary(uniqueKeysWithValues: fillColors.enumerated().map { index, color in (color, index + 2) })
        let borderID: [AnnotationColor: Int] = Dictionary(uniqueKeysWithValues: borderColors.enumerated().map { index, color in (color, index + 1) })
        let customFills = fillColors.map { color in
            #"<fill><patternFill patternType="solid"><fgColor rgb="\#(argb(color))"/><bgColor indexed="64"/></patternFill></fill>"#
        }.joined()
        let customBorders = borderColors.map { color in
            let argb = argb(color)
            return #"<border><left style="thin"><color rgb="\#(argb)"/></left><right style="thin"><color rgb="\#(argb)"/></right><top style="thin"><color rgb="\#(argb)"/></top><bottom style="thin"><color rgb="\#(argb)"/></bottom><diagonal/></border>"#
        }.joined()
        var cellXfs = [
            #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#,
            #"<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>"#,
        ]
        for style in styles.dropFirst() {
            let fill = style.fillColor.flatMap { fillID[$0] } ?? 0
            let border = style.borderColor.flatMap { borderID[$0] } ?? 0
            cellXfs.append(#"<xf numFmtId="0" fontId="0" fillId="\#(fill)" borderId="\#(border)" xfId="0" applyFill="\#(fill == 0 ? 0 : 1)" applyBorder="\#(border == 0 ? 0 : 1)"/>"#)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><sz val="11"/><name val="Aptos"/></font></fonts>
          <fills count="\(2 + fillColors.count)"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\(customFills)</fills>
          <borders count="\(1 + borderColors.count)"><border><left/><right/><top/><bottom/><diagonal/></border>\(customBorders)</borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="\(cellXfs.count)">\(cellXfs.joined())</cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
    }

    private static func uniqueColors(_ colors: [AnnotationColor]) -> [AnnotationColor] {
        var result: [AnnotationColor] = []
        var seen = Set<AnnotationColor>()
        for color in colors where seen.insert(color).inserted {
            result.append(color)
        }
        return result
    }
}

private enum GenotypeViewportExcelExportError: Error, LocalizedError {
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let stderr):
            return "Failed to package Excel workbook: \(stderr)"
        }
    }
}

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func argb(_ color: AnnotationColor) -> String {
    let alpha = Int((color.alpha * 255).rounded())
    let red = Int((color.red * 255).rounded())
    let green = Int((color.green * 255).rounded())
    let blue = Int((color.blue * 255).rounded())
    return String(format: "%02X%02X%02X%02X", alpha, red, green, blue)
}
