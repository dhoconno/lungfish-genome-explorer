import XCTest
@testable import LungfishWorkflow

final class MSASequenceSelectionTests: XCTestCase {
    private func sanitize(_ value: String) -> String {
        let replaced = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        let cleaned = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "sequence" : cleaned
    }

    private let records: [(name: String, sourceFile: String)] = [
        ("MT192765.1 Severe acute respiratory syndrome coronavirus 2", "a.fasta"),
        ("OK091006.1 Influenza A virus segment 4", "a.fasta"),
        ("plain_name", "b.fasta"),
    ]

    func testMatchesExactRawName() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["MT192765.1 Severe acute respiratory syndrome coronavirus 2"],
            records: records,
            sanitize: sanitize
        )
        XCTAssertEqual(kept, [0])
    }

    func testMatchesFirstTokenAccession() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["MT192765.1"], records: records, sanitize: sanitize
        )
        XCTAssertEqual(kept, [0])
    }

    func testMatchesSanitizedDisplayLabel() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["OK091006.1_Influenza_A_virus_segment_4"],
            records: records,
            sanitize: sanitize
        )
        XCTAssertEqual(kept, [1])
    }

    func testReportsEveryUnmatchedNameTogether() {
        XCTAssertThrowsError(
            try MSASequenceSelection.resolve(
                requestedNames: ["nope", "plain_name", "also_missing"],
                records: records,
                sanitize: sanitize
            )
        ) { error in
            XCTAssertEqual(
                error as? MSASequenceSelectionError,
                .unmatched(["nope", "also_missing"])
            )
        }
    }

    func testAmbiguousRequestIsAnErrorNotASilentMultiInclude() {
        let duplicated: [(name: String, sourceFile: String)] = [
            ("SEQ1 first copy", "a.fasta"),
            ("SEQ1 second copy", "b.fasta"),
        ]
        XCTAssertThrowsError(
            try MSASequenceSelection.resolve(
                requestedNames: ["SEQ1"], records: duplicated, sanitize: sanitize
            )
        ) { error in
            guard case .ambiguous(let name, let matches)? = error as? MSASequenceSelectionError else {
                return XCTFail("expected .ambiguous, got \(error)")
            }
            XCTAssertEqual(name, "SEQ1")
            XCTAssertEqual(matches, ["SEQ1 first copy (a.fasta)", "SEQ1 second copy (b.fasta)"])
        }
    }

    func testEarlierTierWinsOverLaterTier() throws {
        // "alpha" is BOTH an exact raw name (index 1) and the first token of
        // index 0. Tier 1 must win, so only index 1 is kept.
        let tricky: [(name: String, sourceFile: String)] = [
            ("alpha beta gamma", "a.fasta"),
            ("alpha", "a.fasta"),
        ]
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["alpha"], records: tricky, sanitize: sanitize
        )
        XCTAssertEqual(kept, [1])
    }
}
