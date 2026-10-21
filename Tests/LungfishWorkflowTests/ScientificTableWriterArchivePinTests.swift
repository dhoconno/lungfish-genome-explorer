import Foundation
import XCTest
@testable import LungfishWorkflow

/// Lane 13.50 (XLSX-FIXED). Pins that passed at the base d3a1fcdd8 and still pass after the fix, which only moves
/// archive metadata (BIO 1 and BIO 7, row P7 of `SCR/lanes/13.50/predictions.md`). The pin of what varied at the base
/// (row P2) went with the fix and `ScientificTableWriterArchiveTests` replaces it.
final class ScientificTableWriterArchivePinTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScientificTableWriterArchivePinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The SHA-256 of each part of the probe's table, measured at the base.
    static let baseDigests: [String: String] = [
        "[Content_Types].xml": "b34a1c9f5b5c0f54f1274272a429578b417e119fdc48bfcd96f25f93f301458f",
        "_rels/.rels": "9f96bb683e71c45171c7ae310bf6c37fb5a834bb9738497ac7084c42ac9c2d9a",
        "xl/_rels/workbook.xml.rels": "1b2fc82d18a622c89e94093d1d5a256857ac9641b8ee51a8290ea82796b1060f",
        "xl/styles.xml": "8709abebc67d483e2d4fc7846d5999a73763ba0c0b17c38c44da3b4fdcd814d1",
        "xl/workbook.xml": "535055660c8586d7855bd4753d366058553a5b674dbc263ee43a36d8f01e4ee2",
        "xl/worksheets/sheet1.xml": "3f88b08d060d32f352aaf1340a5a05a344854a84e702cf6d5372d0dd8034a906",
    ]

    func testPartsKeepTheirBytes() throws {
        let archive = try XLSXArchiveProbe.export("parts.xlsx", in: directory).url
        XCTAssertEqual(try XLSXArchiveProbe.partDigests(of: archive), Self.baseDigests)
    }

    func testTheEntrySetIsTheSixPartsAndTheirFolders() throws {
        let archive = try XLSXArchiveProbe.export("entries.xlsx", in: directory).url
        XCTAssertEqual(
            Set(try XLSXArchiveProbe.entries(of: archive).map(\.name)),
            Set(XLSXArchiveProbe.partNames + XLSXArchiveProbe.folderNames)
        )
    }
}
