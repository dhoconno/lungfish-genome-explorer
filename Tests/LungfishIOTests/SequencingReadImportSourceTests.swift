import XCTest
@testable import LungfishIO

final class SequencingReadImportSourceTests: XCTestCase {
    func testRecognizesBAMCaseInsensitively() {
        XCTAssertTrue(SequencingReadImportSource.isBAM(URL(fileURLWithPath: "/tmp/reads.bam")))
        XCTAssertTrue(SequencingReadImportSource.isBAM(URL(fileURLWithPath: "/tmp/reads.BAM")))
        XCTAssertFalse(SequencingReadImportSource.isBAM(URL(fileURLWithPath: "/tmp/reads.cram")))
    }

    func testSupportedSourcesIncludeFASTQAndBAM() {
        XCTAssertTrue(SequencingReadImportSource.isSupported(URL(fileURLWithPath: "/tmp/reads.fastq.gz")))
        XCTAssertTrue(SequencingReadImportSource.isSupported(URL(fileURLWithPath: "/tmp/reads.fq")))
        XCTAssertTrue(SequencingReadImportSource.isSupported(URL(fileURLWithPath: "/tmp/reads.bam")))
        XCTAssertFalse(SequencingReadImportSource.isSupported(URL(fileURLWithPath: "/tmp/reads.sam")))
    }
}
