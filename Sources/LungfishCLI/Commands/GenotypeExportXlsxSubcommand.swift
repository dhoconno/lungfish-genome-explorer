import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Exports the genotype bundle's annotation sidecar as a standalone
/// auditor-grade XLSX with Overrides + Audit Log sheets.
///
/// This is a focused export — it doesn't reproduce the full
/// pivoted-matrix workbook that the pipeline produces (the bundle's
/// primary `.xlsx` already serves that purpose). Useful for sharing the
/// override history with someone who needs the annotation audit trail
/// without opening the bundle directory.
struct GenotypeExportXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-xlsx",
        abstract: "Export the genotype bundle's analyst annotations as an XLSX file."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundle)
        let sidecar = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
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

        // Hand-rolled minimal XLSX with two sheets: Overrides and Audit Log.
        try writeMinimalXLSX(
            to: outputURL,
            buildDir: buildDir,
            overrides: overrides,
            audit: audit
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
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

    private struct OverrideRow {
        let sample, locus, slot, originalCall, overrideCall, reason, rationale, author, timestamp: String
    }

    private struct AuditRow {
        let action, sample, locus, slot, before, after, author, timestamp: String
    }

    private func writeMinimalXLSX(
        to outputURL: URL,
        buildDir: URL,
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
        try makeOverridesSheet(overrides).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        try makeAuditSheet(audit).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet2.xml"), atomically: true, encoding: .utf8)

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

    private func makeOverridesSheet(_ rows: [OverrideRow]) -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            "Sample", "Locus", "Slot", "Original Call", "Override Call",
            "Reason", "Rationale", "Author", "Timestamp"
        ])
        for (i, r) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                r.sample, r.locus, r.slot, r.originalCall, r.overrideCall,
                r.reason, r.rationale, r.author, r.timestamp
            ])
        }
        sheet += sheetFooter()
        return sheet
    }

    private func makeAuditSheet(_ rows: [AuditRow]) -> String {
        var sheet = sheetHeader()
        sheet += rowXML(index: 1, cells: [
            "Action", "Sample", "Locus", "Slot", "Before", "After",
            "Author", "Timestamp"
        ])
        for (i, r) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: [
                r.action, r.sample, r.locus, r.slot, r.before, r.after,
                r.author, r.timestamp
            ])
        }
        sheet += sheetFooter()
        return sheet
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

    private func rowXML(index: Int, cells: [String]) -> String {
        let cellXML = cells.enumerated().map { (col, value) -> String in
            let ref = "\(columnLetter(col + 1))\(index)"
            let escaped = xmlEscape(value)
            return #"<c r="\#(ref)" t="inlineStr"><is><t>\#(escaped)</t></is></c>"#
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

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
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
        <sheet name="Overrides" sheetId="1" r:id="rId1"/>
        <sheet name="Audit Log" sheetId="2" r:id="rId2"/>
      </sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
    </Relationships>
    """
}

enum GenotypeExportXlsxError: Error, LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed: return "Failed to zip the XLSX archive."
        }
    }
}
