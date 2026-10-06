import XCTest
@testable import LungfishCore

final class FileNameBudgetTests: XCTestCase {
    func testBoundedStemFitsWithExtensionAndCollisionSuffix() {
        let inputs = [
            String(repeating: "a", count: 400),
            String(repeating: "é", count: 150),
            String(repeating: "🧬🦠", count: 80),
        ]
        for input in inputs {
            let stem = FileNameBudget.boundedStem(input, pathExtension: "lungfishtree")
            XCTAssertLessThanOrEqual((stem + "-99.lungfishtree").utf8.count, FileNameBudget.maxComponentBytes)
            XCTAssertFalse(stem.isEmpty)
        }
    }

    func testBoundedStemCutsOnCharacterBoundary() {
        let input = String(repeating: "🧬é", count: 100)
        let stem = FileNameBudget.boundedStem(input, pathExtension: "nwk")
        XCTAssertTrue(input.hasPrefix(stem))
        XCTAssertLessThan(stem.count, input.count)
    }

    func testShortStemUnchanged() {
        XCTAssertEqual(FileNameBudget.boundedStem("tree-1", pathExtension: "lungfishtree"), "tree-1")
        // Names that already fit keep their punctuation (nextAvailableBundleURL is shared).
        XCTAssertEqual(FileNameBudget.boundedStem("_sample_", pathExtension: "lungfishref"), "_sample_")
        XCTAssertEqual(FileNameBudget.boundedStem("", pathExtension: "x"), "untitled")
    }

    func testCutEndIsTrimmedOfSeparators() {
        // The budget for ".lungfishtree" is 200 - 13 - 8 = 179 bytes, so the cut lands after "-_.".
        let input = String(repeating: "a", count: 176) + "-_." + String(repeating: "b", count: 100)
        let stem = FileNameBudget.boundedStem(input, pathExtension: "lungfishtree")
        XCTAssertEqual(stem, String(repeating: "a", count: 176))
    }
}
