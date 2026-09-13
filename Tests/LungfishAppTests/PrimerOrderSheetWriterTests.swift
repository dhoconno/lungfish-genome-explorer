import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class PrimerOrderSheetWriterTests: XCTestCase {
  private let spreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

  func testReplacesEverySampleWithoutDeduplicatingOligosOrMergingSchemePools() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oligos = [oligo("one", pool: "Scheme_1_Pool_1"), oligo("two", pool: "Scheme_2_Pool_1")]
    let receipt = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: .init(),
      selection: selection(oligos), to: directory)
    let workbook = try await xml("xl/workbook.xml", in: directory.appendingPathComponent("primer-order.xlsx"))
    XCTAssertEqual(try workbook.nodes(forXPath: "//*[local-name()='sheet']/@name").compactMap(\.stringValue),
      ["Sheet1", "Order metadata"])
    let uploadWorkbook = try await xml("xl/workbook.xml", in: directory.appendingPathComponent("IDT-oPools.xlsx"))
    XCTAssertEqual(try uploadWorkbook.nodes(forXPath: "//*[local-name()='sheet']/@name").compactMap(\.stringValue), ["Sheet1"])
    let upload = try await xml("xl/worksheets/sheet1.xml", in: directory.appendingPathComponent("IDT-oPools.xlsx"))
    let entries = try upload.nodes(forXPath: "//*[local-name()='row' and @r != '1']/*[local-name()='c' and (starts-with(@r,'A') or starts-with(@r,'B'))]")
    XCTAssertEqual(entries.count, 4)
    XCTAssertEqual(try value("A2", in: upload), "Scheme_1_Pool_1")
    XCTAssertEqual(try value("A3", in: upload), "Scheme_2_Pool_1")
    XCTAssertEqual(try value("B2", in: upload), "ACGTRYSW")
    XCTAssertEqual(try value("B3", in: upload), "ACGTRYSW")
    XCTAssertTrue(try upload.nodes(forXPath: "//*[local-name()='c' and @r='A4']").isEmpty)
    XCTAssertEqual(try upload.nodes(forXPath: "//*[local-name()='mergeCell']/@ref").first?.stringValue, "D3:G19")
    XCTAssertFalse(try upload.nodes(forXPath: "//*[local-name()='c' and @r='D33']").isEmpty)
    let shared = try await xml("xl/sharedStrings.xml", in: directory.appendingPathComponent("IDT-oPools.xlsx"))
    XCTAssertFalse(shared.xmlString.contains("poolOne"))
    XCTAssertFalse(shared.xmlString.contains("CGATAGTC"))
    XCTAssertTrue(shared.xmlString.contains("Mixed-base code for DNA"))
    let template = try Data(contentsOf: directory.appendingPathComponent("template.xlsx"))
    XCTAssertEqual(receipt.templateSHA256, SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(receipt.commands.count, 3)
    for command in receipt.commands {
      XCTAssertEqual(command.exitStatus, 0)
      XCTAssertFalse(command.argv.isEmpty)
      XCTAssertFalse(command.toolVersion.isEmpty)
      XCTAssertNotEqual(command.toolVersion, ProcessInfo.processInfo.operatingSystemVersionString)
      XCTAssertTrue(FileManager.default.fileExists(atPath: command.workingDirectory))
      XCTAssertGreaterThanOrEqual(command.completedAt, command.startedAt)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("workbook-parts/xl/worksheets/sheet2.xml").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("upload-parts/xl/worksheets/sheet1.xml").path))
    let originalSheet = try await xml("xl/worksheets/sheet1.xml", in: directory.appendingPathComponent("template.xlsx"))
    let templateSheet = try XMLDocument(contentsOf: directory.appendingPathComponent("template-parts/xl/worksheets/sheet1.xml"), options: [])
    XCTAssertEqual(templateSheet.xmlString, originalSheet.xmlString, "Retain unmodified extraction output for the unzip provenance step")
  }

  func testMetadataAndCSVPreserveLiteralTextFrozenFiltersAndBlankOptionalFields() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oligos = [oligo("literal", pool: "=SUM(1,1) & <pool> _x0041_")]
    var metadata = PrimerOrderMetadata()
    metadata.name = "=SUM(2,2)"
    metadata.notes = "First line\n\"Quoted\" & <literal>"
    let receipt = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: metadata,
      selection: selection(oligos), to: directory)
    XCTAssertFalse(receipt.templateSHA256.isEmpty)
    let workbook = directory.appendingPathComponent("primer-order.xlsx")
    let sheet = try await xml("xl/worksheets/sheet2.xml", in: workbook)
    XCTAssertEqual(sheet.rootElement()?.uri, spreadsheetNamespace,
      "The saved metadata worksheet must declare the OpenXML spreadsheet namespace")
    XCTAssertTrue(try sheet.nodes(forXPath: "//*[local-name()='f']").isEmpty)
    let text = sheet.rootElement()?.stringValue ?? ""
    XCTAssertTrue(text.contains("=SUM(2,2)"))
    XCTAssertTrue(text.contains("Captured display settings"))
    XCTAssertTrue(text.contains("Minimum observed MSA compatibility (%)"))
    XCTAssertTrue(text.contains("Primer ID"))
    XCTAssertTrue(text.contains("literal"))
    XCTAssertTrue(text.contains("_x005F_x0041_"))
    let csv = try String(contentsOf: directory.appendingPathComponent("ordering.csv"), encoding: .utf8)
    XCTAssertTrue(csv.contains("\"'=SUM(1,1) & <pool> _x0041_\""))
    XCTAssertTrue(csv.contains("\"'=SUM(2,2)\""))
    XCTAssertTrue(csv.contains("\"First line\n\"\"Quoted\"\" & <literal>\""))
    XCTAssertTrue(csv.contains("\"Requested by\",\"Project\",\"Order reference\",\"Order notes\""))
    XCTAssertTrue(csv.contains("\"'=SUM(2,2)\",\"\",\"\",\"\",\"First line"))
    let upload = try await xml("xl/worksheets/sheet1.xml", in: directory.appendingPathComponent("IDT-oPools.xlsx"))
    XCTAssertEqual(try value("B2", in: upload), "ACGTRYSW", "Order notes must never infer sequence modifications")
  }

  func testMoreThanTemplateSampleRowsRetainsEverySavedSequence() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oligos = (0..<60).map { oligo("primer-\($0)", pool: "Pool_1") }
    _ = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: .init(),
      selection: selection(oligos), to: directory)
    let sheet = try await xml("xl/worksheets/sheet1.xml", in: directory.appendingPathComponent("IDT-oPools.xlsx"))
    XCTAssertEqual(try value("A61", in: sheet), "Pool_1")
    XCTAssertEqual(try value("B61", in: sheet), "ACGTRYSW")
    XCTAssertEqual(try sheet.nodes(forXPath: "//*[local-name()='dimension']/@ref").first?.stringValue, "A1:G61")
  }

  func testMetadataLayoutFitsWrappedIdentifiersAndMultilineNotes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let longID = String(repeating: "source_identifier/", count: 60)
    let oligos = [oligo(longID, pool: "Pool_1"), oligo("short", pool: "Pool_1")]
    var metadata = PrimerOrderMetadata()
    metadata.notes = "First line\nSecond line\nThird line"
    _ = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: metadata,
      selection: selection(oligos), to: directory)
    let sheet = try await xml("xl/worksheets/sheet2.xml", in: directory.appendingPathComponent("primer-order.xlsx"))
    XCTAssertEqual(try sheet.nodes(forXPath: "//*[local-name()='sheetView']/@showGridLines").first?.stringValue, "0")
    let columns = try sheet.nodes(forXPath: "//*[local-name()='col']").compactMap { $0 as? XMLElement }
    let widths = try columns.map { try XCTUnwrap(Double($0.attribute(forName: "width")?.stringValue ?? "")) }
    XCTAssertEqual(widths[0], 43)
    XCTAssertEqual(widths[1], 62)
    XCTAssertGreaterThanOrEqual(widths[2], 48)
    for column in [6, 7, 10] { XCTAssertGreaterThanOrEqual(widths[column], 70) }
    for column in [8, 9] { XCTAssertGreaterThanOrEqual(widths[column], 64) }
    let rows = try sheet.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']").compactMap { $0 as? XMLElement }
    let heights = try rows.map { try XCTUnwrap(Double($0.attribute(forName: "ht")?.stringValue ?? "")) }
    XCTAssertTrue(heights.allSatisfy { (20...409).contains($0) })
    XCTAssertGreaterThanOrEqual(heights[5], 45, "The notes row must accommodate all three explicit lines")
    XCTAssertGreaterThan(heights[heights.count - 2], heights[heights.count - 1],
      "Long identifiers need more wrapped lines than the shorter oligo row")
    XCTAssertGreaterThanOrEqual(heights[heights.count - 3], 30, "Wrapped mapping headers need two readable lines")
    let longRow = try XCTUnwrap(rows.dropLast().last?.attribute(forName: "r")?.stringValue)
    XCTAssertEqual(try value("G\(longRow)", in: sheet), longID, "Layout must preserve the complete saved identifier")
  }

  func testRefusesExistingOutputBeforeWritingOtherFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sentinel = directory.appendingPathComponent("ordering.csv")
    try Data("keep".utf8).write(to: sentinel)
    let oligos = [oligo("one", pool: "Pool_1")]
    do {
      _ = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: .init(),
        selection: selection(oligos), to: directory)
      XCTFail("Existing output must be preserved")
    } catch { }
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ordering.csv"])
  }

  private func oligo(_ id: String, pool: String) -> PrimerOrderOligo {
    .init(primerID: id, targetID: "target-\(id)", sourceResultID: "result-\(id)", schemeLabel: "Scheme \(id)",
      poolName: pool, pool: 1, referenceID: "reference-\(id)", name: "\(id)_RIGHT_1", sequence: "ACGTRYSW",
      start: 10, end: 18, strand: "-", ampliconIDs: ["amplicon-\(id)"],
      compatibility: .init(matchingRows: 1, assessableRows: 2, totalRows: 3))
  }

  private func selection(_ oligos: [PrimerOrderOligo]) -> PrimerOrderSelection {
    .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), analysisURL: URL(fileURLWithPath: "/fixture.lungfishprimeranalysis"),
      manifest: .init(analysisID: UUID(), runID: UUID(), inputs: [], results: [], artifacts: [],
        provenance: .init(relativePath: "provenance.json", role: "provenance", format: "json", sha256: "", byteSize: 0),
        grouping: .combined, publishedRootPath: "/fixture.lungfishprimeranalysis"),
      settings: .init(filterByCompatibility: true, minimumCompatibilityPercent: 50), compatibilityReady: true,
      compatibilitySummaries: [:], selectedPrimerIDs: oligos.map(\.primerID))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("primer-order-writer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func xml(_ member: String, in archive: URL) async throws -> XMLDocument {
    let result = try await NativeToolRunner.shared.runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
      arguments: ["-p", archive.path, member], timeout: 30)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    return try XMLDocument(xmlString: result.stdout, options: [])
  }

  private func value(_ coordinate: String, in document: XMLDocument) throws -> String? {
    try document.nodes(forXPath: "//*[local-name()='c' and @r='\(coordinate)']/*[local-name()='is']").first?.stringValue
  }
}
