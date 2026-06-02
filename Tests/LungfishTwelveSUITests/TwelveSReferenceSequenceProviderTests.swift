import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSReferenceSequenceProviderTests: XCTestCase {
    private func writeFASTA(_ text: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twelve-s-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("reference.fasta")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMapsTargetIDsToSequences() throws {
        let url = try writeFASTA(">human-a desc\nACGTACGT\n>dog\nTTTTGGGG\n")
        let provider = TwelveSReferenceSequenceProvider(referenceURL: url)
        let seqs = provider.sequences(forTargetIDs: ["human-a", "dog"])
        XCTAssertEqual(seqs.map(\.targetID), ["human-a", "dog"])
        XCTAssertEqual(seqs.first?.sequence, "ACGTACGT")
    }

    func testMissingTargetOmittedAndMissingFileEmpty() throws {
        let url = try writeFASTA(">human-a\nACGT\n")
        let provider = TwelveSReferenceSequenceProvider(referenceURL: url)
        XCTAssertEqual(provider.sequences(forTargetIDs: ["nope"]).count, 0)

        let missing = TwelveSReferenceSequenceProvider(
            referenceURL: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).fasta"))
        XCTAssertEqual(missing.sequences(forTargetIDs: ["human-a"]).count, 0)
    }

    func testPreservesRequestedOrderAndIsRepeatable() throws {
        let url = try writeFASTA(">a\nAAAA\n>b\nCCCC\n>c\nGGGG\n")
        let provider = TwelveSReferenceSequenceProvider(referenceURL: url)
        XCTAssertEqual(provider.sequences(forTargetIDs: ["c", "a"]).map(\.targetID), ["c", "a"])
        // second call uses the cache and returns the same result
        XCTAssertEqual(provider.sequences(forTargetIDs: ["c", "a"]).map(\.sequence), ["GGGG", "AAAA"])
    }
}
