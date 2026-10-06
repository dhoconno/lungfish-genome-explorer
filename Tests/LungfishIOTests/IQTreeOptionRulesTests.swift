import Foundation
import XCTest
@testable import LungfishIO

/// Fix lane F2 (review m2, m8, m9). The IQ-TREE option rules the CLI and the Build Tree dialog share.
final class IQTreeOptionRulesTests: XCTestCase {
    /// Every spelling IQ-TREE 3.1.3 accepted when run on a scratch copy of the sarcopterygian fixture.
    func testEveryAcceptedAliasOfACuratedFlagIsReserved() {
        let expected: [String: IQTreeCuratedOption] = [
            "-s": .alignment, "--msa": .alignment, "--aln": .alignment,
            "--prefix": .output, "-pre": .output,
            "-m": .model, "--model": .model, "--modelomatic": .model,
            "-T": .threads, "--threads": .threads, "-nt": .threads,
            "--seed": .seed, "-seed": .seed,
            "-B": .ufBoot, "-bb": .ufBoot, "--ufboot": .ufBoot,
            "--alrt": .shALRT, "-alrt": .shALRT,
            "-o": .outgroup,
            "-st": .sequenceType, "--seqtype": .sequenceType,
        ]
        XCTAssertEqual(IQTreeOptionRules.reservedFlags, expected)
    }

    func testStandardAndLocalBootstrapStayAllowed() {
        for flag in ["-b", "--boot", "--lbp", "-lbp", "--abayes", "-bnni", "--threads-max"] {
            XCTAssertNil(IQTreeOptionRules.reservedFlags[flag], flag)
        }
    }

    func testFirstReservedFlagReadsFlagEqualsValueForms() {
        let found = IQTreeOptionRules.firstReservedFlag(in: ["-bnni", "--model=GTR", "-T", "4"])
        XCTAssertEqual(found?.flag, "--model")
        XCTAssertEqual(found?.option, .model)
        XCTAssertNil(IQTreeOptionRules.firstReservedFlag(in: ["-b", "100", "-bnni"]))
    }

    func testCuratedOptionsNameTheCLIOptionAndTheDialogControl() {
        XCTAssertEqual(IQTreeCuratedOption.threads.cliName, "--threads")
        XCTAssertEqual(IQTreeCuratedOption.threads.dialogName, "Threads")
        XCTAssertEqual(IQTreeCuratedOption.alignment.cliName, "the input bundle argument")
        XCTAssertEqual(IQTreeCuratedOption.sequenceType.dialogName, "Sequence type")
    }

    func testModelSelectionOnlyReadsTheBaseBeforePlus() {
        for model in ["MF", "mf", "MF+MERGE", "TESTONLY", "testmergeonly", "TESTNEWONLY+F"] {
            XCTAssertTrue(IQTreeOptionRules.isModelSelectionOnly(model), model)
        }
        for model in ["MFP", "MFP+MERGE", "TEST", "GTR+F+I+G4", ""] {
            XCTAssertFalse(IQTreeOptionRules.isModelSelectionOnly(model), model)
        }
    }

    func testBootstrapAndLocalBootstrapAddUnorderedSupport() {
        for arguments in [["-b", "100"], ["--boot", "100"], ["--lbp", "1000"], ["-lbp", "1000"], ["-b=100"]] {
            XCTAssertTrue(IQTreeOptionRules.addsUnorderedSupport(arguments), "\(arguments)")
        }
        XCTAssertFalse(IQTreeOptionRules.addsUnorderedSupport(["--abayes", "-bnni"]))
        XCTAssertEqual(
            IQTreeOptionRules.unorderedSupportWarning,
            "Support labels were not recorded because -b/--lbp adds values in an order LGE does not know."
        )
    }

    func testCodonFrameNeedsEveryRangeOnACodonBoundaryAndInWholeCodons() {
        XCTAssertNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [1...9]))
        XCTAssertNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [4...9, 31...36]))
        XCTAssertNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [10...12, 1...3]))
        XCTAssertEqual(
            IQTreeOptionRules.codonFrameMessage(columnRanges: [2...10]),
            "Codon sequence types need whole codons. Each column range must start at column 1, 4, 7 and so on "
                + "and span a multiple of 3 columns, but 2-10 does not."
        )
        // Two ranges that each break the frame can still add up to a multiple of 3.
        XCTAssertNotNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [1...4, 5...9]))
        XCTAssertTrue(IQTreeOptionRules.codonFrameMessage(columnRanges: [1...3, 7...7])?.contains("but 7 does not") == true)
        XCTAssertNotNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [1...11]))
    }

    /// Fix G (re-review minor 5): with no columns chosen, the message talks about the whole
    /// alignment length instead of column ranges.
    func testCodonFrameMessageForTheWholeAlignmentNamesItsLength() {
        XCTAssertNil(IQTreeOptionRules.codonFrameMessage(columnRanges: [1...9], wholeAlignment: true))
        XCTAssertEqual(
            IQTreeOptionRules.codonFrameMessage(columnRanges: [1...11], wholeAlignment: true),
            "Codon sequence types need whole codons, so the alignment length must be a multiple of 3 (got 11)."
        )
        XCTAssertTrue(
            IQTreeOptionRules.codonFrameMessage(columnRanges: [1...11])?.contains("but 1-11 does not") == true
        )
    }

    func testColumnRangesReadTextInOrderAndBlankAsTheWholeAlignment() {
        XCTAssertEqual(IQTreeOptionRules.columnRanges(nil, alignedLength: 12), [1...12])
        XCTAssertEqual(IQTreeOptionRules.columnRanges(" ", alignedLength: 12), [1...12])
        XCTAssertEqual(IQTreeOptionRules.columnRanges("7-9, 1-3,5", alignedLength: 12), [7...9, 1...3, 5...5])
        XCTAssertNil(IQTreeOptionRules.columnRanges("0-3", alignedLength: 12))
        XCTAssertNil(IQTreeOptionRules.columnRanges("4-2", alignedLength: 12))
        XCTAssertNil(IQTreeOptionRules.columnRanges("10-13", alignedLength: 12))
        XCTAssertNil(IQTreeOptionRules.columnRanges("a-b", alignedLength: 12))
        XCTAssertNil(IQTreeOptionRules.columnRanges("1-2-3", alignedLength: 12))
    }
}
