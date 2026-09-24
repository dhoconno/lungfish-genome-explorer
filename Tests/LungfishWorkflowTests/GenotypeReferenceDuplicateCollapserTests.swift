import XCTest
@testable import LungfishWorkflow

/// GEN-04 (D12): identical reference sequences, including reverse
/// complements, are collapsed onto one representative before mapping.
final class GenotypeReferenceDuplicateCollapserTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The audit's `e1` fixture: eight references with one identical 200 bp
    /// amplicon (two of them stored reverse complemented, one lowercase) and
    /// a ninth with six SNPs.
    func testE1FixtureCollapsesEightIdenticalReferencesToOneGroup() throws {
        let amplicon = Self.deterministicSequence(length: 200)
        var snpVariant = Array(amplicon)
        for position in [20, 50, 80, 110, 140, 170] {
            snpVariant[position] = snpVariant[position] == "A" ? "C" : "A"
        }
        var records: [(String, String)] = []
        for index in 1...8 {
            let name = "MHC_00\(index)g\(index)|haplotypes=M\(index)"
            let sequence: String
            switch index {
            case 3, 6: sequence = Self.reverseComplement(amplicon)
            case 7: sequence = amplicon.lowercased()
            default: sequence = amplicon
            }
            records.append((name, sequence))
        }
        records.append(("MHC_009g9|haplotypes=M1", String(snpVariant)))
        let fasta = directory.appendingPathComponent("e1.fasta")
        try Self.writeFASTA(records, to: fasta)

        let collapse = try GenotypeReferenceDuplicateCollapser.collapse(
            referenceFASTAURL: fasta,
            outputDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )

        let expectedMembers = (1...8).map { "MHC_00\($0)g\($0)|haplotypes=M\($0)" }
        XCTAssertEqual(collapse.groups, [
            GenotypeReferenceDuplicateCollapser.Group(
                representative: expectedMembers[0],
                members: expectedMembers,
                reverseComplementMembers: [expectedMembers[2], expectedMembers[5]]
            ),
        ])
        XCTAssertEqual(collapse.collapsedRecordCount, 7)
        XCTAssertNotEqual(collapse.mappingReferenceFASTAURL, fasta)
        let collapsedHeaders = try String(contentsOf: collapse.mappingReferenceFASTAURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix(">") }
        XCTAssertEqual(collapsedHeaders, [">\(expectedMembers[0])", ">MHC_009g9|haplotypes=M1"])

        let groupsURL = try XCTUnwrap(collapse.groupsJSONURL)
        let map = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: groupsURL))
        XCTAssertEqual(map, [expectedMembers[0]: expectedMembers])
        let warning = try XCTUnwrap(collapse.warning)
        XCTAssertTrue(warning.contains("7 duplicate record(s)"), warning)

        // The user's reference is left untouched.
        XCTAssertEqual(try GenotypeReferenceDuplicateCollapser.duplicateGroups(inFASTA: fasta).count, 1)
    }

    func testUniqueReferenceIsMappedUnchanged() throws {
        let fasta = directory.appendingPathComponent("unique.fasta")
        try Self.writeFASTA([
            ("A1", "ACGTACGTAAGG"),
            ("A2", "ACGTACGTAAGC"),
            ("A3", "TTTTGGGGCCCA"),
        ], to: fasta)

        let collapse = try GenotypeReferenceDuplicateCollapser.collapse(
            referenceFASTAURL: fasta,
            outputDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )

        XCTAssertEqual(collapse.mappingReferenceFASTAURL, fasta)
        XCTAssertTrue(collapse.groups.isEmpty)
        XCTAssertNil(collapse.groupsJSONURL)
        XCTAssertNil(collapse.warning)
    }

    // MARK: - Helpers

    private static func deterministicSequence(length: Int) -> String {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let bases: [Character] = ["A", "C", "G", "T"]
        return String((0..<length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return bases[Int(state >> 62)]
        })
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "T": return "A"
            case "G": return "C"
            case "C": return "G"
            default: return base
            }
        })
    }

    private static func writeFASTA(_ records: [(String, String)], to url: URL) throws {
        let text = records.map { ">\($0.0)\n\($0.1)\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
