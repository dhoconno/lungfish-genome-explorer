import Foundation
import XCTest
@testable import LungfishCore

final class PrimerAnalysisAnnotationLinkTests: XCTestCase {
    private let link = PrimerAnalysisAnnotationLink(
        analysisID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        resultID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        inputID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    )

    func testLinkedAnnotationRetainsIdentityAndMetadataThroughJSON() throws {
        let original = annotation()
        let linked = try link.attaching(to: original)
        let restored = try JSONDecoder().decode(SequenceAnnotation.self, from: JSONEncoder().encode(linked))

        XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: restored), link)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.parentID, original.parentID)
        XCTAssertEqual(restored.intervals, original.intervals)
        XCTAssertEqual(restored.strand, .reverse)
        XCTAssertEqual(restored.name, "example feature")
        XCTAssertEqual(restored.chromosome, "example")
        XCTAssertEqual(restored.note, "retained note")
        XCTAssertEqual(restored.qualifierValues("db_xref"), ["example:one", "example:two"])
        XCTAssertNil(try PrimerAnalysisAnnotationLink.read(from: original))
    }

    func testRepeatedAttachmentIsIdempotent() throws {
        let once = try link.attaching(to: annotation())
        let twice = try link.attaching(to: once)
        XCTAssertEqual(twice.id, once.id)
        XCTAssertEqual(twice.qualifiers.count, once.qualifiers.count)
        XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: twice), link)
        XCTAssertEqual(twice.qualifierValues("lungfish_primer_result_id"), [link.resultID.uuidString])
    }

    func testDifferentResultCannotSilentlyReplaceExistingLink() throws {
        let linked = try link.attaching(to: annotation())
        let other = PrimerAnalysisAnnotationLink(analysisID: link.analysisID, resultID: UUID(), inputID: link.inputID)
        XCTAssertThrowsError(try other.attaching(to: linked)) { error in
            XCTAssertEqual(error as? PrimerAnalysisAnnotationLink.LinkError, .conflictingLink)
        }
        XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: linked), link)
    }

    func testPartialOrMalformedLinksAreRejectedInsteadOfTreatedAsUnlinked() throws {
        let cases: [[String: AnnotationQualifier]] = [
            ["lungfish_primer_link_version": AnnotationQualifier("1")],
            ["lungfish_primer_analysis_id": AnnotationQualifier(link.analysisID.uuidString)],
            ["lungfish_primer_link_version": AnnotationQualifier("2")],
            ["lungfish_primer_link_version": AnnotationQualifier(["1", "1"])],
        ]
        for qualifiers in cases {
            var feature = annotation()
            feature.qualifiers.merge(qualifiers) { _, new in new }
            XCTAssertThrowsError(try PrimerAnalysisAnnotationLink.read(from: feature))
            XCTAssertThrowsError(try link.attaching(to: feature))
        }

        for value in [AnnotationQualifier("bad-uuid"), AnnotationQualifier(""),
                      AnnotationQualifier([link.inputID.uuidString, UUID().uuidString])] {
            var feature = try link.attaching(to: annotation())
            feature.qualifiers["lungfish_primer_input_id"] = value
            XCTAssertThrowsError(try PrimerAnalysisAnnotationLink.read(from: feature))
        }
    }

    func testUnrelatedAnalysisMetadataIsNotMistakenForPrimerLink() throws {
        var feature = annotation()
        feature.qualifiers["analysis_id"] = AnnotationQualifier("unrelated")
        XCTAssertNil(try PrimerAnalysisAnnotationLink.read(from: feature))
        let attached = try link.attaching(to: feature)
        XCTAssertEqual(attached.qualifier("analysis_id"), "unrelated")
    }

    private func annotation() -> SequenceAnnotation {
        SequenceAnnotation(
            type: .misc_feature, name: "example feature", chromosome: "example",
            intervals: [.init(start: 0, end: 3), .init(start: 6, end: 9)], strand: .reverse,
            qualifiers: ["db_xref": AnnotationQualifier(["example:one", "example:two"])],
            note: "retained note", parentID: UUID()
        )
    }
}
