import XCTest
@testable import LungfishIO

final class BarcodeKitSuggestionEngineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarcodeKitSuggestionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFASTQ(sequences: [String], to url: URL) throws {
        var lines: [String] = []
        lines.reserveCapacity(sequences.count * 4)
        for (idx, sequence) in sequences.enumerated() {
            lines.append("@read_\(idx)")
            lines.append(sequence)
            lines.append("+")
            lines.append(String(repeating: "I", count: sequence.count))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testSuggestKitsFindsPacBioSet() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mix forward and swapped orientations for asymmetric pair detection.
        let informative = (0..<12).map { _ in "ACACACAGACTGTGAGTTTTTTGATATACGCGAGAGAG" } // bc1002 ... bc1050
        let swapped = (0..<6).map { _ in "GATATACGCGAGAGAGCCCCCCACACACAGACTGTGAG" }     // bc1050 ... bc1002
        let noise = (0..<2).map { _ in "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG" }
        let fastqURL = dir.appendingPathComponent("sample.fastq")
        try writeFASTQ(sequences: informative + swapped + noise, to: fastqURL)

        let suggestions = try await BarcodeKitSuggestionEngine.suggestKits(
            in: fastqURL,
            kits: [IlluminaBarcodeKitRegistry.truseqSingleA, IlluminaBarcodeKitRegistry.pacbioSequel384V1],
            sampleReadLimit: 20,
            minimumHitFraction: 0.25
        )

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertEqual(suggestions.first?.kitID, "pacbio-sequel-384-v1")
        XCTAssertGreaterThanOrEqual(suggestions.first?.hitFraction ?? 0, 0.8)
    }

    func testDominantBarcodeIDsReturnsObservedPacBioBarcodes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sequences = [
            "ACACACAGACTGTGAGAAAAAAGATATACGCGAGAGAG",
            "GATATACGCGAGAGAGTTTTTTACACACAGACTGTGAG",
            "ACACACAGACTGTGAGCCCCCCGATATACGCGAGAGAG",
            "ACACACAGACTGTGAGGGGGGGGATATACGCGAGAGAG",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ]
        let fastqURL = dir.appendingPathComponent("sample.fastq")
        try writeFASTQ(sequences: sequences, to: fastqURL)

        let dominant = try await BarcodeKitSuggestionEngine.dominantBarcodeIDs(
            in: fastqURL,
            kit: IlluminaBarcodeKitRegistry.pacbioSequel384V1,
            sampleReadLimit: 5,
            minimumHitFraction: 0.1,
            maxCandidates: 10
        )

        XCTAssertTrue(dominant.contains("bc1002"))
        XCTAssertTrue(dominant.contains("bc1050"))
    }
}
