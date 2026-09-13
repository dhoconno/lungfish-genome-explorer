import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimalSchemeOrderSheetTests: XCTestCase {
  func testOrderSheetGroupsPoolsRetainsAlternativesAndProtectsSpreadsheetCells() throws {
    let bed = Data("ref\t4\t6\t=LEFT_alt1\t2\t-\tac\nref\t0\t2\tLEFT\t1\t+\tAN\nref\t2\t4\tLEFT_alt2\t1\t+\tAC\n".utf8)
    let csv = try XCTUnwrap(String(data: PrimalSchemeOrderSheet.csv(fromBED: bed), encoding: .utf8))
    let rows = csv.components(separatedBy: "\r\n")
    XCTAssertTrue(rows[0].contains("Sequence (5′–3′)"))
    XCTAssertTrue(rows[1].hasPrefix("\"1\",\"LEFT\",\"AN\""))
    XCTAssertTrue(rows[2].hasPrefix("\"1\",\"LEFT_alt2\""))
    XCTAssertTrue(rows[3].hasPrefix("\"2\",\"'=LEFT_alt1\",\"AC\""))
    XCTAssertEqual(rows.count, 5)
    XCTAssertEqual(try PrimalSchemeOrderSheet.csv(fromBED: bed), try PrimalSchemeOrderSheet.csv(fromBED: bed))
  }

  func testMappedBindingSpanCanDifferFromSynthesisLength() throws {
    let csv = String(decoding: try PrimalSchemeOrderSheet.csv(fromBED:
      Data("ref\t0\t3\tP\t1\t+\tAC\n".utf8)), as: UTF8.self)
    XCTAssertTrue(csv.contains("\"AC\",\"2\",\"ref\",\"1\",\"3\""))
  }

  func testInvalidNativeRecordsCannotProduceMisleadingOrderSheet() {
    for line in ["ref\t0\t2\tP\t0\t+\tAC", "ref\t0\t3\tP\t1\t+\t", "ref\t0\t2\tP\t1\t?\tAC", "ref\t0\t2\tP\t1\t+\tA!"] {
      XCTAssertThrowsError(try PrimalSchemeOrderSheet.csv(fromBED: Data(line.utf8)))
    }
  }

  func testNativeOligoOrientationIsPreservedAndCsvQuotesAreEscaped() throws {
    let csv = String(decoding: try PrimalSchemeOrderSheet.csv(fromBED:
      Data("@ref\t0\t4\tA,\"B\t1\t-\tAGTC\n".utf8)), as: UTF8.self)
    XCTAssertTrue(csv.contains("\"A,\"\"B\",\"AGTC\""))
    XCTAssertTrue(csv.contains("\"'@ref\""))
    XCTAssertTrue(csv.contains("\"1\",\"4\",\"'-\""))
  }
}
