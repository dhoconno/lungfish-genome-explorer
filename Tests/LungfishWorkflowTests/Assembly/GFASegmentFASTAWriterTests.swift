import XCTest
@testable import LungfishWorkflow

final class GFASegmentFASTAWriterTests: XCTestCase {
    func testHifiasmPrimaryContigsAreExportedFromGFA() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gfa-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gfa = """
        H\tVN:Z:1.0
        S\tctg0001\tACGTACGT
        S\tctg0002\tTTTTCCCC
        """
        let gfaURL = tempDir.appendingPathComponent("sample.bp.p_ctg.gfa")
        try gfa.write(to: gfaURL, atomically: true, encoding: .utf8)

        let fastaURL = tempDir.appendingPathComponent("contigs.fa")
        try GFASegmentFASTAWriter.writePrimaryContigs(from: gfaURL, to: fastaURL)

        let fasta = try String(contentsOf: fastaURL, encoding: .utf8)
        XCTAssertTrue(fasta.contains(">ctg0001"))
        XCTAssertTrue(fasta.contains("ACGTACGT"))
        XCTAssertTrue(fasta.contains(">ctg0002"))
        XCTAssertTrue(fasta.contains("TTTTCCCC"))
    }
}
