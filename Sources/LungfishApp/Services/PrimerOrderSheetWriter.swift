import AppKit
import CryptoKit
import Darwin
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LungfishWorkflow

/// Writes ordering derivatives from frozen, verified saved oligos. No design runtime is used.
enum PrimerOrderSheetWriter {
  struct Command: Codable, Sendable {
    let argv: [String]
    let toolVersion: String
    let workingDirectory: String
    let stderr: String
    let exitStatus: Int32
    let startedAt: Date
    let completedAt: Date
  }

  struct Receipt: Sendable {
    let templateSHA256: String
    let commands: [Command]
  }

  private static let templateSHA256 = "06011c8a0c29ef15aefb91fe7d7ce0af00e7dabbd5fab82dc726608b2ae962b4"
  private static let outputNames = ["template.xlsx", "ordering.csv", "IDT-oPools.xlsx", "primer-order.xlsx", "template-parts", "upload-parts", "workbook-parts"]
  private static let spreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

  static func write(oligos: [PrimerOrderOligo], metadata: PrimerOrderMetadata,
                    selection: PrimerOrderSelection, to directory: URL) async throws -> Receipt {
    try Task.checkCancellation()
    guard !oligos.isEmpty, oligos.count < 1_048_576,
      oligos.allSatisfy({ !$0.poolName.isEmpty && !$0.sequence.isEmpty && $0.sequence.utf8.allSatisfy {
        "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0)
      } }) else { throw invalid("Choose saved oligos with pool names and valid DNA sequences.") }
    var info = stat()
    guard directory.isFileURL, lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      throw invalid("The staged order directory must be an existing real directory.")
    }
    for name in outputNames { try requireAbsent(directory.appendingPathComponent(name)) }
    guard let resource = Bundle.module.url(forResource: "IDT-oPools-template", withExtension: "xlsx", subdirectory: "PrimerOrdering") else {
      throw invalid("The bundled IDT ordering template is unavailable.")
    }
    let template = try Data(contentsOf: resource)
    let hash = SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
    guard hash == templateSHA256 else { throw invalid("The bundled IDT ordering template failed its integrity check.") }
    let unzipVersion = try await toolVersion(of: "/usr/bin/unzip")
    let zipVersion = try await toolVersion(of: "/usr/bin/zip")
    try Task.checkCancellation()
    let retainedTemplate = directory.appendingPathComponent("template.xlsx")
    try template.write(to: retainedTemplate, options: .withoutOverwriting)
    let templateParts = directory.appendingPathComponent("template-parts", isDirectory: true)
    let uploadParts = directory.appendingPathComponent("upload-parts", isDirectory: true)
    let workbookParts = directory.appendingPathComponent("workbook-parts", isDirectory: true)
    var commands: [Command] = []
    commands.append(try await run("/usr/bin/unzip", version: unzipVersion,
      arguments: ["-q", retainedTemplate.path, "-d", templateParts.path], directory: directory))
    try Task.checkCancellation()
    try FileManager.default.copyItem(at: templateParts, to: uploadParts)
    try populateTemplate(at: uploadParts, oligos: oligos)
    // Retain both generated OpenXML packages so the recorded ZIP commands can be replayed.
    try FileManager.default.copyItem(at: uploadParts, to: workbookParts)
    try addMetadataSheet(at: workbookParts, oligos: oligos, metadata: metadata, selection: selection)
    try Data(csv(oligos: oligos, metadata: metadata).utf8)
      .write(to: directory.appendingPathComponent("ordering.csv"), options: .withoutOverwriting)
    for (parts, filename) in [(uploadParts, "IDT-oPools.xlsx"), (workbookParts, "primer-order.xlsx")] {
      try Task.checkCancellation()
      let output = directory.appendingPathComponent(filename)
      try requireAbsent(output)
      commands.append(try await run("/usr/bin/zip", version: zipVersion, arguments: ["-X", "-q", "-r", output.path,
        "[Content_Types].xml", "_rels", "docProps", "xl"], directory: parts))
    }
    try Task.checkCancellation()
    return Receipt(templateSHA256: hash, commands: commands)
  }

  private static func run(_ executable: String, version: String, arguments: [String], directory: URL) async throws -> Command {
    let startedAt = Date()
    let result = try await NativeToolRunner.shared.runProcess(executableURL: URL(fileURLWithPath: executable),
      arguments: arguments, workingDirectory: directory, timeout: 120, maxStderrBytes: nil)
    let command = Command(argv: [executable] + arguments, toolVersion: version, workingDirectory: directory.path,
      stderr: result.stderr, exitStatus: result.exitCode, startedAt: startedAt, completedAt: Date())
    guard result.isSuccess else { throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.exitCode)): \(result.stderr)") }
    return command
  }

  private static func toolVersion(of executable: String) async throws -> String {
    do {
      let result = try await NativeToolRunner.shared.runProcess(executableURL: URL(fileURLWithPath: executable),
        arguments: ["-v"], timeout: 5, toolName: URL(fileURLWithPath: executable).lastPathComponent + " version")
      let prefix = executable.hasSuffix("/unzip") ? "UnZip" : "This is Zip"
      if result.isSuccess, let line = result.combinedOutput.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { $0.hasPrefix(prefix) }) {
        return line
      }
    } catch is CancellationError { throw CancellationError() }
    catch { /* A binary digest identifies the executable when a version probe is unavailable. */ }
    try Task.checkCancellation()
    let bytes = try Data(contentsOf: URL(fileURLWithPath: executable))
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return "Executable SHA-256 \(hash) (version unavailable)"
  }

  private static func populateTemplate(at root: URL, oligos: [PrimerOrderOligo]) throws {
    let path = root.appendingPathComponent("xl/worksheets/sheet1.xml")
    let document = try XMLDocument(contentsOf: path, options: .nodePreserveAll)
    guard let sheet = document.rootElement(), let data = sheet.elements(forName: "sheetData").first,
      let dimension = sheet.elements(forName: "dimension").first else { throw invalid("The IDT template worksheet is invalid.") }
    var rows: [Int: XMLElement] = [:]
    for row in data.elements(forName: "row") {
      guard let number = Int(row.attribute(forName: "r")?.stringValue ?? "") else { throw invalid("The IDT template row is invalid.") }
      rows[number] = row
      guard number > 1 else { continue }
      for cell in row.elements(forName: "c") {
        let coordinate = cell.attribute(forName: "r")?.stringValue ?? ""
        if coordinate == "A\(number)" || coordinate == "B\(number)" { cell.detach() }
      }
    }
    for (index, oligo) in oligos.enumerated() {
      try Task.checkCancellation()
      let number = index + 2
      let row = rows[number] ?? element("row", attributes: ["r": String(number)])
      if rows[number] == nil { rows[number] = row; data.addChild(row) }
      row.insertChild(textCell("B\(number)", value: oligo.sequence, style: 1), at: 0)
      row.insertChild(textCell("A\(number)", value: oligo.poolName, style: 1), at: 0)
    }
    let lastRow = max(rows.keys.max() ?? 1, oligos.count + 1)
    setAttribute(dimension, "ref", "A1:G\(lastRow)")
    if let columns = sheet.elements(forName: "cols").first,
      let poolColumn = columns.elements(forName: "col").first(where: { $0.attribute(forName: "min")?.stringValue == "1" }) {
      let existing = Double(poolColumn.attribute(forName: "width")?.stringValue ?? "") ?? 12
      setAttribute(poolColumn, "width", String(max(existing, min(60, Double(oligos.map(\.poolName.count).max() ?? 0) + 2))))
      setAttribute(poolColumn, "customWidth", "1")
    }
    try removeUnusedSampleStrings(from: document, root: root)
    try document.xmlData.write(to: path, options: .atomic)
  }

  private static func removeUnusedSampleStrings(from worksheet: XMLDocument, root: URL) throws {
    let path = root.appendingPathComponent("xl/sharedStrings.xml")
    let strings = try XMLDocument(contentsOf: path, options: .nodePreserveAll)
    guard let table = strings.rootElement() else { throw invalid("The IDT template shared strings are invalid.") }
    let entries = table.elements(forName: "si")
    let references = try worksheet.nodes(forXPath: "//*[local-name()='c' and @t='s']/*[local-name()='v']")
    let used = try Set(references.map { node -> Int in
      guard let index = Int(node.stringValue ?? ""), entries.indices.contains(index) else {
        throw invalid("The IDT template contains an invalid shared-string reference.")
      }
      return index
    }).sorted()
    let remapping = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element, $0.offset) })
    for node in references {
      guard let index = Int(node.stringValue ?? ""), let replacement = remapping[index] else { throw invalid("The IDT template string could not be retained.") }
      node.stringValue = String(replacement)
    }
    table.setChildren(used.map { entries[$0].copy() as! XMLNode })
    setAttribute(table, "count", String(references.count))
    setAttribute(table, "uniqueCount", String(used.count))
    try strings.xmlData.write(to: path, options: .atomic)
  }

  private static func addMetadataSheet(at root: URL, oligos: [PrimerOrderOligo], metadata: PrimerOrderMetadata,
                                       selection: PrimerOrderSelection) throws {
    let workbookPath = root.appendingPathComponent("xl/workbook.xml")
    let workbook = try XMLDocument(contentsOf: workbookPath, options: .nodePreserveAll)
    guard let sheets = workbook.rootElement()?.elements(forName: "sheets").first else { throw invalid("The IDT workbook is invalid.") }
    sheets.addChild(element("sheet", attributes: ["name": "Order metadata", "sheetId": "2", "r:id": "rIdOrderMetadata"]))
    try workbook.xmlData.write(to: workbookPath, options: .atomic)
    let relationshipPath = root.appendingPathComponent("xl/_rels/workbook.xml.rels")
    let relationships = try XMLDocument(contentsOf: relationshipPath, options: .nodePreserveAll)
    relationships.rootElement()?.addChild(element("Relationship", attributes: ["Id": "rIdOrderMetadata",
      "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet", "Target": "worksheets/sheet2.xml"]))
    try relationships.xmlData.write(to: relationshipPath, options: .atomic)
    let contentPath = root.appendingPathComponent("[Content_Types].xml")
    let content = try XMLDocument(contentsOf: contentPath, options: .nodePreserveAll)
    content.rootElement()?.addChild(element("Override", attributes: ["PartName": "/xl/worksheets/sheet2.xml",
      "ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"]))
    try content.xmlData.write(to: contentPath, options: .atomic)
    try updateSheetProperties(at: root.appendingPathComponent("docProps/app.xml"))
    let styles = try appendMetadataStyles(at: root.appendingPathComponent("xl/styles.xml"))
    let rows = metadataRows(oligos: oligos, metadata: metadata, selection: selection)
    let sheet = XMLElement(name: "worksheet", uri: spreadsheetNamespace)
    // Assigning uri alone does not serialize the default namespace declaration.
    sheet.addNamespace(XMLNode.namespace(withName: "", stringValue: spreadsheetNamespace) as! XMLNode)
    sheet.addChild(element("dimension", attributes: ["ref": "A1:\(columnName(csvHeader.count))\(rows.count)"]))
    let views = XMLElement(name: "sheetViews"), view = element("sheetView", attributes: ["workbookViewId": "0", "showGridLines": "0"])
    view.addChild(element("pane", attributes: ["ySplit": "1", "topLeftCell": "A2", "activePane": "bottomLeft", "state": "frozen"]))
    views.addChild(view); sheet.addChild(views)
    let columns = XMLElement(name: "cols")
    for index in 1...csvHeader.count {
      columns.addChild(element("col", attributes: ["min": String(index), "max": String(index),
        "width": String(metadataColumnWidths[index - 1]), "customWidth": "1"]))
    }
    sheet.addChild(columns)
    let data = XMLElement(name: "sheetData")
    for (index, entry) in rows.enumerated() {
      try Task.checkCancellation()
      let number = index + 1
      let row = element("row", attributes: ["r": String(number), "ht": String(metadataRowHeight(entry)), "customHeight": "1"])
      for (column, value) in entry.values.enumerated() {
        let coordinate = "\(columnName(column + 1))\(number)"
        if entry.numericColumns.contains(column), !value.isEmpty {
          let cell = element("c", attributes: ["r": coordinate, "s": String(styles.body)])
          cell.addChild(XMLElement(name: "v", stringValue: value))
          row.addChild(cell)
        } else { row.addChild(textCell(coordinate, value: value, style: entry.header ? styles.header : styles.body)) }
      }
      data.addChild(row)
    }
    sheet.addChild(data)
    let document = XMLDocument(rootElement: sheet)
    document.version = "1.0"; document.characterEncoding = "UTF-8"
    try document.xmlData.write(to: root.appendingPathComponent("xl/worksheets/sheet2.xml"), options: .withoutOverwriting)
  }

  private static let csvHeader = ["Pool name", "Oligo name", "Sequence (5′–3′)", "Length (nt)", "Scheme",
    "Pool number", "Primer ID", "Target ID", "Source result ID", "Reference ID", "Amplicon IDs (JSON)",
    "Start (1-based inclusive)", "End (1-based inclusive)", "Strand", "Compatible rows", "Assessable rows",
    "Unassessed rows", "Total alignment rows", "Observed MSA compatibility (%)", "Order name",
    "Requested by", "Project", "Order reference", "Order notes"]

  // Keep the two-column order details compact while fitting the identity mapping below.
  private static let metadataColumnWidths: [Double] = [43, 62, 48, 14, 28, 14, 72, 72, 64, 64, 72, 22,
    22, 12, 18, 18, 18, 22, 26, 36, 28, 28, 28, 62]

  private static func metadataRowHeight(_ row: MetadataRow) -> Double {
    let font = row.header
      ? NSFont(name: "Calibri-Bold", size: 11) ?? NSFont(name: "Arial-BoldMT", size: 11) ?? NSFont.boldSystemFont(ofSize: 11)
      : NSFont(name: "Calibri", size: 11) ?? NSFont(name: "Arial", size: 11) ?? NSFont.systemFont(ofSize: 11)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    var contentHeight = lineHeight
    for (column, value) in row.values.enumerated() {
      // Excel widths use default-font digit units (about 5.25 pt); reserve cell padding.
      let width = max(1, metadataColumnWidths[column] * 5.25 - 10)
      let bounds = (value as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
      let hardLines = value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").count
      contentHeight = max(contentHeight, ceil(bounds.height), CGFloat(hardLines) * lineHeight)
    }
    let minimum = row.header && contentHeight > lineHeight ? 30.0 : 20.0
    return min(409, max(minimum, Double(ceil(contentHeight)) + 6))
  }

  private static func oligoRow(_ oligo: PrimerOrderOligo, metadata: PrimerOrderMetadata) -> [String] {
    let compatibility = oligo.compatibility
    return [oligo.poolName, oligo.name, oligo.sequence, String(oligo.sequence.count), oligo.schemeLabel,
      String(oligo.pool), oligo.primerID, oligo.targetID, oligo.sourceResultID, oligo.referenceID, json(oligo.ampliconIDs),
      String(oligo.start + 1), String(oligo.end), oligo.strand,
      compatibility.map { String($0.matchingRows) } ?? "", compatibility.map { String($0.assessableRows) } ?? "",
      compatibility.map { String($0.unknownRows) } ?? "", compatibility.map { String($0.totalRows) } ?? "",
      compatibility?.percent.map { String($0) } ?? "", metadata.name, metadata.requestedBy,
      metadata.project, metadata.orderReference, metadata.notes]
  }

  private static func csv(oligos: [PrimerOrderOligo], metadata: PrimerOrderMetadata) -> String {
    ([csvHeader] + oligos.map { oligoRow($0, metadata: metadata) }).map { row in
      row.map { value in
        let trigger = value.trimmingCharacters(in: .whitespacesAndNewlines).first.map { "=+-@".contains($0) } ?? false
        return "\"" + (trigger ? "'" + value : value).replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }.joined(separator: ",")
    }.joined(separator: "\r\n") + "\r\n"
  }

  private struct MetadataRow {
    let values: [String]
    var header = false
    var numericColumns: Set<Int> = []
  }

  private static func metadataRows(oligos: [PrimerOrderOligo], metadata: PrimerOrderMetadata,
                                    selection: PrimerOrderSelection) -> [MetadataRow] {
    let settings = selection.settings
    var rows = [MetadataRow(values: ["Order metadata"], header: true)]
    let details = [
      ["Order name", metadata.name], ["Requested by", metadata.requestedBy], ["Project", metadata.project],
      ["Order reference", metadata.orderReference], ["Order notes", metadata.notes],
      ["Scope", "Filtered derivative of saved oligos; no new design or optimization."],
      ["Sequence orientation", "Saved 5′–3′ oligos; no inferred modifications."],
      ["Source analysis", selection.analysisURL.lastPathComponent],
      ["Analysis ID", selection.manifest.analysisID.uuidString], ["Run ID", selection.manifest.runID.uuidString],
      ["Captured at", ISO8601DateFormatter().string(from: selection.capturedAt)],
      ["Exported oligos", String(oligos.count)], ["Named pools", String(Set(oligos.map(\.poolName)).count)],
      ["Source schemes", String(Set(oligos.map(\.sourceResultID)).count)],
    ]
    rows += details.map { MetadataRow(values: $0,
      numericColumns: ["Exported oligos", "Named pools", "Source schemes"].contains($0[0]) ? [1] : []) }
    rows.append(.init(values: []))
    rows.append(.init(values: ["Captured display settings"], header: true))
    let filters = [
      ["Forward oligos shown", String(settings.showForward)], ["Reverse oligos shown", String(settings.showReverse)],
      ["Saved amplicon spans shown", String(settings.showAmplicons)], ["Identity dots shown", String(settings.showIdentityDots)],
      ["Compatibility filter enabled", String(settings.filterByCompatibility)],
      ["Minimum observed MSA compatibility (%)", String(settings.minimumCompatibilityPercent)],
      ["Compatibility calculation ready", String(selection.compatibilityReady)],
      ["Compatibility filter applied", String(settings.filterByCompatibility && selection.compatibilityReady)],
      ["Keep unassessed oligos", String(settings.showUnassessed)],
      ["Individually hidden oligos", String(settings.hiddenPrimerIDs.count)],
      ["Hidden pools", String(settings.hiddenPoolIDs.count)],
      ["Compatibility definition", "Compatible / assessable alignment rows; unresolved rows excluded."],
    ]
    rows += filters.map { MetadataRow(values: $0, numericColumns:
      ["Minimum observed MSA compatibility (%)", "Individually hidden oligos", "Hidden pools"].contains($0[0]) ? [1] : []) }
    rows += settings.hiddenPrimerIDs.sorted().map { MetadataRow(values: ["Hidden primer ID", $0]) }
    rows += settings.hiddenPoolIDs.sorted().map { MetadataRow(values: ["Hidden pool ID", $0]) }
    rows.append(.init(values: []))
    rows.append(.init(values: ["Exported oligo identities"], header: true))
    rows.append(.init(values: csvHeader, header: true))
    rows += oligos.map { MetadataRow(values: oligoRow($0, metadata: metadata), numericColumns: [3, 5, 11, 12, 14, 15, 16, 17, 18]) }
    return rows
  }

  private static func appendMetadataStyles(at path: URL) throws -> (body: Int, header: Int) {
    let document = try XMLDocument(contentsOf: path, options: .nodePreserveAll)
    guard let root = document.rootElement(), let fonts = root.elements(forName: "fonts").first,
      let formats = root.elements(forName: "cellXfs").first else { throw invalid("The IDT template styles are invalid.") }
    let fontID = fonts.elements(forName: "font").count
    let normal = XMLElement(name: "font")
    normal.addChild(element("sz", attributes: ["val": "11"]))
    normal.addChild(element("name", attributes: ["val": "Calibri"]))
    fonts.addChild(normal)
    let bold = normal.copy() as! XMLElement; bold.insertChild(XMLElement(name: "b"), at: 0); fonts.addChild(bold)
    setAttribute(fonts, "count", String(fontID + 2))
    let styleID = formats.elements(forName: "xf").count
    for index in 0...1 {
      let format = element("xf", attributes: ["numFmtId": "0", "fontId": String(fontID + index),
        "fillId": "0", "borderId": "0", "xfId": "0", "applyFont": "1", "applyAlignment": "1"])
      format.addChild(element("alignment", attributes: ["vertical": "top", "wrapText": "1"]))
      formats.addChild(format)
    }
    setAttribute(formats, "count", String(styleID + 2))
    try document.xmlData.write(to: path, options: .atomic)
    return (styleID, styleID + 1)
  }

  private static func updateSheetProperties(at path: URL) throws {
    let document = try XMLDocument(contentsOf: path, options: .nodePreserveAll)
    if let titles = try document.nodes(forXPath: "//*[local-name()='TitlesOfParts']/*[local-name()='vector']").first as? XMLElement {
      titles.addChild(XMLElement(name: "vt:lpstr", stringValue: "Order metadata"))
      setAttribute(titles, "size", "2")
    }
    let sheetCount = try document.nodes(forXPath: "//*[local-name()='HeadingPairs']//*[local-name()='i4']").first
    sheetCount?.stringValue = "2"
    try document.xmlData.write(to: path, options: .atomic)
  }

  private static func element(_ name: String, attributes: [String: String]) -> XMLElement {
    let node = XMLElement(name: name)
    for key in attributes.keys.sorted() { node.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key]!) as! XMLNode) }
    return node
  }

  private static func setAttribute(_ node: XMLElement, _ name: String, _ value: String) {
    node.removeAttribute(forName: name)
    node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
  }

  private static func textCell(_ coordinate: String, value: String, style: Int) -> XMLElement {
    let cell = element("c", attributes: ["r": coordinate, "t": "inlineStr", "s": String(style)])
    let inline = XMLElement(name: "is"), text = XMLElement(name: "t", stringValue: ooxmlText(value))
    setAttribute(text, "xml:space", "preserve")
    inline.addChild(text); cell.addChild(inline)
    return cell
  }

  private static func ooxmlText(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var result = ""
    for index in scalars.indices {
      let scalar = scalars[index]
      if scalar == "_", index + 6 < scalars.count, scalars[index + 1] == "x" || scalars[index + 1] == "X", scalars[index + 6] == "_",
        scalars[(index + 2)...(index + 5)].allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }) {
        result += "_x005F_"
      } else if scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (0x20...0xD7FF).contains(scalar.value)
        || (0xE000...0xFFFD).contains(scalar.value) || (0x10000...0x10FFFF).contains(scalar.value) {
        result.unicodeScalars.append(scalar)
      } else { result += String(format: "_x%04X_", scalar.value) }
    }
    return result
  }

  private static func columnName(_ number: Int) -> String {
    var number = number, result = ""
    while number > 0 { number -= 1; result.insert(Character(UnicodeScalar(65 + number % 26)!), at: result.startIndex); number /= 26 }
    return result
  }

  private static func json(_ strings: [String]) -> String {
    // String arrays are always JSON-encodable; retain exact identity boundaries.
    String(decoding: try! JSONEncoder().encode(strings), as: UTF8.self)
  }

  private static func requireAbsent(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) != 0, errno == ENOENT else { throw invalid("An order output already exists: \(url.lastPathComponent)") }
  }

  private static func invalid(_ message: String) -> NSError {
    NSError(domain: "PrimerOrderSheetWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
