import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI

final class SequenceSummaryBoundaryTests: XCTestCase {
    func testStatsOddTotalMatchesBundleNxAndIncludesN90() async throws {
        let data = try await jsonOutput(fasta: ">a\nAAA\n>b\nCC\n>c\nGG\n") { input in
            let command = try StatsSubcommand.parse([input.path, "--format", "json"])
            try await command.run()
        }
        XCTAssertEqual(data["n50"] as? Int, 2)
        XCTAssertEqual(data["n90"] as? Int, 2)
    }

    func testRequestedCompositionDoesNotJoinIndependentRecords() async throws {
        let data = try await composition(">a\nAA\n>b\nCC\n")
        let pairs = try XCTUnwrap(data["dinucleotideFrequencies"] as? [[String: Any]])
        XCTAssertEqual(Set(pairs.compactMap { $0["dinucleotide"] as? String }), ["AA", "CC"])
        XCTAssertEqual(pairs.compactMap { $0["frequency"] as? Double }, [0.5, 0.5])
        let codons = try XCTUnwrap(data["codonUsage"] as? [[String: Any]])
        XCTAssertTrue(codons.isEmpty)
    }

    func testCompositionFrameResetsAndAmbiguousWindowsAreExcluded() async throws {
        let data = try await composition(">a\nAANAA\n>b\nCCCT\n")
        let codons = try XCTUnwrap(data["codonUsage"] as? [[String: Any]])
        XCTAssertEqual(codons.compactMap { $0["codon"] as? String }, ["CCC"])
        XCTAssertEqual(codons.first?["frequency"] as? Double, 1)
        let pairs = try XCTUnwrap(data["dinucleotideFrequencies"] as? [[String: Any]])
        XCTAssertEqual(Set(pairs.compactMap { $0["dinucleotide"] as? String }), ["AA", "CC", "CT"])
    }

    func testStatsNoGCAndLengthDistributionHaveObservableMeaning() async throws {
        let data = try await jsonOutput(fasta: ">a\nGGG\n>b\nCC\n>c\nAA\n") { input in
            let command = try StatsSubcommand.parse([
                input.path, "--no-gc", "--length-distribution", "--format", "json"
            ])
            try await command.run()
        }
        XCTAssertNil(data["gcContent"])
        XCTAssertEqual(data["lengthDistribution"] as? [String: Int], ["2": 2, "3": 1])
    }

    func testPerSequenceDoesNotSilentlyTruncateAfterFiftyRecords() async throws {
        let input = (1...51).map { ">record\($0)\nAC\n" }.joined()
        let data = try await jsonOutput(fasta: input) { input in
            let command = try StatsSubcommand.parse([input.path, "--per-sequence", "--no-gc", "--format", "json"])
            try await command.run()
        }
        let records = try XCTUnwrap(data["perSequence"] as? [[String: Any]])
        XCTAssertEqual(records.count, 51)
        XCTAssertEqual(records.last?["name"] as? String, "record51")
        XCTAssertTrue(records.allSatisfy { $0["gcContent"] == nil })
    }

    private func composition(_ fasta: String) async throws -> [String: Any] {
        try await jsonOutput(fasta: fasta) { input in
            let command = try CompositionSubcommand.parse([
                input.path, "--codons", "--dinucleotides", "--format", "json"
            ])
            try await command.run()
        }
    }

    // XCTest cases run serially within this process. A temporary file avoids pipe
    // capacity deadlock while exercising the actual CLI writer, not a test-only API.
    private func jsonOutput(
        fasta: String,
        operation: (URL) async throws -> Void
    ) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.fa")
        let output = root.appendingPathComponent("stdout.json")
        try fasta.write(to: input, atomically: true, encoding: .utf8)
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw POSIXError(.EBADF) }
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            try? handle.close()
        }
        guard dup2(handle.fileDescriptor, STDOUT_FILENO) >= 0 else { throw POSIXError(.EBADF) }
        try await operation(input)
        fflush(stdout)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    }
}
