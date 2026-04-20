import XCTest
@testable import LungfishIO

final class FASTQOperationTestHelperTests: XCTestCase {

    func testWriteInterleavedPEFASTQProducesReverseComplementMatesWithExpectedOverlap() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "InterleavedPEFixture")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("reads.fastq")
        let overlapLength = 18

        try FASTQOperationTestHelper.writeInterleavedPEFASTQ(
            to: fastqURL,
            pairCount: 3,
            readLength: 40,
            overlapLength: overlapLength
        )

        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: fastqURL)
        XCTAssertEqual(records.count, 6)

        for index in stride(from: 0, to: records.count, by: 2) {
            let r1 = records[index]
            let r2 = records[index + 1]

            XCTAssertTrue(r1.identifier.hasSuffix("/1"))
            XCTAssertTrue(r2.identifier.hasSuffix("/2"))

            let r2Forward = FASTQOperationTestHelper.reverseComplement(r2.sequence)
            XCTAssertEqual(
                String(r1.sequence.suffix(overlapLength)),
                String(r2Forward.prefix(overlapLength)),
                "Synthetic mates should share a deterministic overlap once R2 is reverse-complemented"
            )
        }
    }
}
