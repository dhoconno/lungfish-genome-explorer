import AppKit
import XCTest
@testable import LungfishKit
@testable import LungfishIO

@MainActor
final class MiniBAMReadCopyTests: XCTestCase {
    func testContextMenuOffersFASTQAndFASTAReadSequenceCopies() throws {
        let controller = MiniBAMViewController()
        _ = controller.view

        let titles = try XCTUnwrap(controller.view.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .menu?
            .items
            .map(\.title))

        XCTAssertTrue(titles.contains("Copy Read Sequence (FASTQ)"))
        XCTAssertTrue(titles.contains("Copy Read Sequence (FASTA)"))
    }

    func testTestingReadFASTAUsesReadNameAndSequenceOnly() {
        let read = AlignedRead(
            name: "read-1",
            flag: 0,
            chromosome: "NC_001",
            position: 10,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: 4)],
            sequence: "ACGT",
            qualities: [30, 31, 32, 33],
            mdTag: "4"
        )

        XCTAssertEqual(MiniBAMViewController.testingReadFASTA(read), ">read-1\nACGT")
    }
}
