import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class PrimerAnalysisAnnotationLinkRoundtripTests: XCTestCase {
    func testSQLiteRenderingPreservesAnalysisReferencesAcrossRecreatedAnnotationIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bed = root.appendingPathComponent("features.bed")
        let databaseURL = root.appendingPathComponent("annotations.sqlite")
        let attributes = "lungfish_primer_link_version=1;lungfish_primer_analysis_id=00000000-0000-0000-0000-000000000001;lungfish_primer_result_id=00000000-0000-0000-0000-000000000002;lungfish_primer_input_id=00000000-0000-0000-0000-000000000003;note=retained%20metadata"
        let columns = ["example", "0", "9", "example feature", "0", "-", "0", "9", "0,0,0", "2", "3,3", "0,6", "misc_feature", attributes]
        try (columns.joined(separator: "\t") + "\n").write(to: bed, atomically: true, encoding: .utf8)
        XCTAssertEqual(try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: databaseURL), 1)

        let database = try AnnotationDatabase(url: databaseURL)
        let row = try XCTUnwrap(database.query().first)
        let firstView = row.toAnnotation()
        let reopenedView = row.toAnnotation()
        let expected = PrimerAnalysisAnnotationLink(
            analysisID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            resultID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            inputID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )

        XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: firstView), expected)
        XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: reopenedView), expected)
        XCTAssertEqual(reopenedView.qualifier("note"), "retained metadata")
        XCTAssertEqual(reopenedView.intervals.map(\.start), [0, 6])
        XCTAssertEqual(reopenedView.intervals.map(\.end), [3, 9])
        XCTAssertEqual(reopenedView.strand, .reverse)
    }
}
