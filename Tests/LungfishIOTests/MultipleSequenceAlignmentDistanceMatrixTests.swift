// MultipleSequenceAlignmentDistanceMatrixTests.swift - Shared MSA distance matrix service
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class MultipleSequenceAlignmentDistanceMatrixTests: XCTestCase {
    /// The fixture and expected TSV are the same ones `MSACommandTests` asserts for
    /// `lungfish-cli msa distance`, so the GUI matrix and the CLI file must agree.
    private let records = [
        MSAAlignedRecord(name: "seq1", sequence: "ACGT"),
        MSAAlignedRecord(name: "seq2", sequence: "A-GT"),
        MSAAlignedRecord(name: "seq3", sequence: "ACAT"),
    ]

    private func matrix(
        _ sequences: [String],
        _ options: MSADistanceOptions = MSADistanceOptions()
    ) throws -> MSADistanceMatrix {
        try MSADistanceMatrix(
            records: sequences.enumerated().map { MSAAlignedRecord(name: "r\($0.offset)", sequence: $0.element) },
            options: options
        )
    }

    // MARK: - Layout and defaults

    func testIdentityMatrixMatchesCLILayout() throws {
        let matrix = try MSADistanceMatrix(records: records, options: MSADistanceOptions())

        XCTAssertEqual(matrix.names, ["seq1", "seq2", "seq3"])
        XCTAssertEqual(matrix.recordIndices, [0, 1, 2])
        XCTAssertEqual(
            matrix.tsv,
            "row\tseq1\tseq2\tseq3\nseq1\t1.000000\t1.000000\t0.750000\nseq2\t1.000000\t1.000000\t0.666667\nseq3\t0.750000\t0.666667\t1.000000\n"
        )
        XCTAssertEqual(matrix.values[0][2], 0.75, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[2][0], 0.75, accuracy: 1e-12, "matrix is symmetric")
        let detail = matrix.detail(row: 1, column: 2)
        XCTAssertEqual(detail.comparableSites, 3, "gap in seq2 is skipped pairwise")
        XCTAssertEqual(detail.identicalSites, 2)
        XCTAssertEqual(detail.differences, 1)
        XCTAssertEqual(detail.gapSkipped, 1)
        XCTAssertEqual(detail.ambiguitySkipped, 0)
        XCTAssertEqual(matrix.undefinedPairCount, 0)
        XCTAssertEqual(matrix.saturatedPairCount, 0)
    }

    func testDefaultOptionsAndConvenienceInitAgree() throws {
        XCTAssertEqual(
            MSADistanceOptions(),
            MSADistanceOptions(model: .identity, gaps: .pairwise, order: .alignment, alphabet: .nucleotide)
        )
        XCTAssertEqual(
            try MSADistanceMatrix(records: records, model: .pDistance).tsv,
            try MSADistanceMatrix(records: records, options: MSADistanceOptions(model: .pDistance)).tsv
        )
    }

    func testPDistanceIsOneMinusIdentity() throws {
        let matrix = try MSADistanceMatrix(records: records, options: MSADistanceOptions(model: .pDistance))
        XCTAssertEqual(matrix.values[0][2], 0.25, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[1][2], 1 - 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[0][0], 0, accuracy: 1e-12)
    }

    func testUniquePairsListEachUnorderedPairOnce() throws {
        let matrix = try MSADistanceMatrix(records: records, model: .identity)
        let pairs = matrix.uniquePairs
        XCTAssertEqual(pairs.map(\.id), ["0:1", "0:2", "1:2"])
        XCTAssertEqual(pairs.map { "\($0.rowName)/\($0.columnName)" }, ["seq1/seq2", "seq1/seq3", "seq2/seq3"])
        XCTAssertEqual(pairs.map(\.formattedValue), ["1.000000", "0.750000", "0.666667"])
        XCTAssertEqual(pairs.map(\.comparableSites), [3, 4, 3])
    }

    func testNoComparableSitesGivesNaNAndIsCounted() throws {
        let matrix = try matrix(["AC--", "--GT"])
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertTrue(detail.isUndefined)
        XCTAssertFalse(detail.isSaturated)
        XCTAssertEqual(detail.formattedValue, "nan")
        XCTAssertEqual(detail.comparableSites, 0)
        XCTAssertEqual(detail.gapSkipped, 4)
        XCTAssertEqual(matrix.undefinedPairCount, 1)
        XCTAssertEqual(matrix.uniquePairs.first?.sortableValue, -Double.infinity)
        XCTAssertTrue(matrix.tsv.contains("\tnan"))
    }

    func testDiagonalIsNaNForARowWithNoComparableSite() throws {
        let matrix = try matrix(["NN--", "ACGT"])
        XCTAssertTrue(matrix.values[0][0].isNaN, "an all-N or all-gap row shows nan on the diagonal")
        XCTAssertEqual(matrix.values[1][1], 1)
        XCTAssertEqual(matrix.undefinedPairCount, 1, "the diagonal is not counted")
    }

    func testComparisonIsCaseInsensitiveAndTreatsDotAsGap() throws {
        let matrix = try matrix(["acgt", "AC.T"])
        XCTAssertEqual(matrix.values[0][1], 1, accuracy: 1e-12)
        XCTAssertEqual(matrix.detail(row: 0, column: 1).comparableSites, 3)
    }

    func testUnequalAlignedLengthsThrow() {
        XCTAssertThrowsError(try matrix(["ACGT", "ACG"])) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .unequalAlignedLengths)
        }
    }

    func testSingleRowHasNoPairs() throws {
        let matrix = try MSADistanceMatrix(records: [records[0]], model: .identity)
        XCTAssertTrue(matrix.uniquePairs.isEmpty)
        XCTAssertEqual(matrix.tsv, "row\tseq1\nseq1\t1.000000\n")
    }

    // MARK: - Ambiguity is missing data (P3, phylo memo section 2)

    func testSharedNIsSkippedNotCountedAsAMatch() throws {
        let matrix = try matrix(["ACGTN", "ACGTN"])
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.comparableSites, 4)
        XCTAssertEqual(detail.ambiguitySkipped, 1)
        XCTAssertEqual(detail.value, 1.0, accuracy: 1e-12)
    }

    func testNAgainstABaseIsSkippedNotCountedAsAMismatch() throws {
        let matrix = try matrix(["ACGTN", "ACGTA"])
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.comparableSites, 4)
        XCTAssertEqual(detail.differences, 0)
        XCTAssertEqual(detail.value, 1.0, accuracy: 1e-12)
    }

    func testIUPACCodesAreSkipped() throws {
        let matrix = try matrix(["ACGTR", "ACGTR"])
        XCTAssertEqual(matrix.detail(row: 0, column: 1).comparableSites, 4)
        let mixed = try self.matrix(["ACGTRYKMSWBDHV?", "ACGTAAAAAAAAAAA"])
        XCTAssertEqual(mixed.detail(row: 0, column: 1).comparableSites, 4)
        XCTAssertEqual(mixed.detail(row: 0, column: 1).ambiguitySkipped, 11)
    }

    func testUracilEqualsThymine() throws {
        let matrix = try matrix(["ACGU", "ACGT"])
        XCTAssertEqual(matrix.values[0][1], 1.0, accuracy: 1e-12)
        XCTAssertEqual(matrix.detail(row: 0, column: 1).comparableSites, 4)
    }

    func testProteinCountsAsparagineAndSkipsX() throws {
        let matrix = try matrix(["MNX", "MNA"], MSADistanceOptions(alphabet: .protein))
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.comparableSites, 2, "N is asparagine in protein and compares")
        XCTAssertEqual(detail.value, 1.0, accuracy: 1e-12)
    }

    func testProteinSkipsStop() throws {
        let matrix = try matrix(["MN*", "MNA"], MSADistanceOptions(alphabet: .protein))
        XCTAssertEqual(matrix.detail(row: 0, column: 1).comparableSites, 2)
    }

    func testProteinSkipsBZJAndQuestionMarkButComparesOAndU() throws {
        let matrix = try matrix(["BZJ?OU", "AAAAOU"], MSADistanceOptions(alphabet: .protein))
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.comparableSites, 2, "O and U are real residues (Pyl, Sec)")
        XCTAssertEqual(detail.ambiguitySkipped, 4)
    }

    func testGapAgainstAmbiguityCountsAsAGapSkip() throws {
        let detail = try matrix(["-AC", "NAC"]).detail(row: 0, column: 1)
        XCTAssertEqual(detail.gapSkipped, 1)
        XCTAssertEqual(detail.ambiguitySkipped, 0)
    }

    // MARK: - Corrected distances (P1, P2)

    func testJC69Formula() throws {
        let matrix = try matrix(["ACGTACGTAC", "ACGTACGTAA"], MSADistanceOptions(model: .jc69))
        XCTAssertEqual(matrix.values[0][1], -0.75 * log(1 - 4.0 / 3.0 * 0.1), accuracy: 1e-12)
        XCTAssertEqual(matrix.detail(row: 0, column: 1).formattedValue, "0.107326")
        XCTAssertEqual(MSADistanceMatrix.formatValue(matrix.values[0][0]), "0.000000", "no negative zero")
    }

    func testK2PFormulaWithHandCountedTransitionsAndTransversions() throws {
        // Two A->G transitions and one C->A transversion over 20 sites: P = 0.1, Q = 0.05.
        let matrix = try matrix(
            ["AAAAAAAAAA" + "CCCCCCCCCC", "GGAAAAAAAA" + "ACCCCCCCCC"],
            MSADistanceOptions(model: .k2p)
        )
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.comparableSites, 20)
        XCTAssertEqual(detail.transitions, 2)
        XCTAssertEqual(detail.transversions, 1)
        XCTAssertEqual(detail.differences, 3)
        XCTAssertEqual(detail.value, -0.5 * log(0.75) - 0.25 * log(0.9), accuracy: 1e-12)
        XCTAssertEqual(detail.formattedValue, "0.170181")
    }

    func testTransitionClassesIncludeUracil() throws {
        let detail = try matrix(["AGCU", "GACT"]).detail(row: 0, column: 1)
        XCTAssertEqual(detail.transitions, 2, "A<->G is a transition")
        XCTAssertEqual(detail.transversions, 0)
        let pyrimidine = try matrix(["CU", "UC"]).detail(row: 0, column: 1)
        XCTAssertEqual(pyrimidine.transitions, 2, "C<->U is a transition, U treated as T")
        let transversion = try matrix(["AGCT", "CTAG"]).detail(row: 0, column: 1)
        XCTAssertEqual(transversion.transversions, 4)
        XCTAssertEqual(transversion.transitions, 0)
    }

    func testPoissonFormulaForProtein() throws {
        let matrix = try matrix(["MKVLAAGHWE", "MKVLAAGHYY"], MSADistanceOptions(model: .poisson, alphabet: .protein))
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertEqual(detail.differences, 2)
        XCTAssertEqual(detail.transitions, 0, "protein has no transition classes")
        XCTAssertEqual(detail.transversions, 0)
        XCTAssertEqual(detail.value, -log(0.8), accuracy: 1e-12)
        XCTAssertEqual(detail.formattedValue, "0.223144")
    }

    func testJC69SaturatesAtThreeQuartersExactly() throws {
        let matrix = try matrix(["AAAA", "ACGT"], MSADistanceOptions(model: .jc69))
        let detail = matrix.detail(row: 0, column: 1)
        XCTAssertTrue(detail.isSaturated)
        XCTAssertFalse(detail.isUndefined)
        XCTAssertEqual(detail.formattedValue, "inf")
        XCTAssertEqual(matrix.saturatedPairCount, 1)
        XCTAssertEqual(matrix.undefinedPairCount, 0)
        XCTAssertEqual(matrix.tsv, "row\tr0\tr1\nr0\t0.000000\tinf\nr1\tinf\t0.000000\n")
    }

    func testK2PSaturatesWhenEitherLogArgumentIsNotPositive() throws {
        // All transversions: 1 - 2Q = -1.
        XCTAssertTrue(try matrix(["AAAA", "CCTT"], MSADistanceOptions(model: .k2p)).detail(row: 0, column: 1).isSaturated)
        // Half transitions: 1 - 2P - Q = 0.
        XCTAssertTrue(try matrix(["AAAA", "GGAA"], MSADistanceOptions(model: .k2p)).detail(row: 0, column: 1).isSaturated)
        // One transition in four: finite.
        XCTAssertFalse(try matrix(["AAAA", "GAAA"], MSADistanceOptions(model: .k2p)).detail(row: 0, column: 1).isSaturated)
    }

    func testPoissonSaturatesWhenEverySiteDiffers() throws {
        let matrix = try matrix(["MK", "LV"], MSADistanceOptions(model: .poisson, alphabet: .protein))
        XCTAssertTrue(matrix.detail(row: 0, column: 1).isSaturated)
        XCTAssertEqual(matrix.saturatedPairCount, 1)
    }

    func testNaNAndInfinityAreDistinct() throws {
        let matrix = try matrix(["AAAA", "ACGT", "----"], MSADistanceOptions(model: .jc69))
        XCTAssertEqual(matrix.saturatedPairCount, 1)
        XCTAssertEqual(matrix.undefinedPairCount, 2)
        XCTAssertEqual(MSADistanceMatrix.formatValue(.nan), "nan")
        XCTAssertEqual(MSADistanceMatrix.formatValue(.infinity), "inf")
        XCTAssertEqual(MSADistanceMatrix.formatValue(0.5), "0.500000")
    }

    func testModelAlphabetValidity() {
        XCTAssertEqual(MSADistanceModel.models(for: .nucleotide), [.identity, .pDistance, .jc69, .k2p])
        XCTAssertEqual(MSADistanceModel.models(for: .protein), [.identity, .pDistance, .poisson])
        XCTAssertThrowsError(try matrix(["MK", "MV"], MSADistanceOptions(model: .jc69, alphabet: .protein))) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .modelNotValidForAlphabet(.jc69, .protein))
        }
        XCTAssertThrowsError(try matrix(["MK", "MV"], MSADistanceOptions(model: .k2p, alphabet: .protein))) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .modelNotValidForAlphabet(.k2p, .protein))
        }
        XCTAssertThrowsError(try matrix(["AC", "AG"], MSADistanceOptions(model: .poisson, alphabet: .nucleotide))) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .modelNotValidForAlphabet(.poisson, .nucleotide))
            XCTAssertTrue(error.localizedDescription.contains("nucleotide"))
        }
    }

    func testModelFlagsAndNames() {
        XCTAssertEqual(MSADistanceModel.allCases.map(\.rawValue), ["identity", "p-distance", "jc69", "k2p", "poisson"])
        XCTAssertEqual(MSADistanceModel.allCases.map(\.displayName), [
            "Identity", "p-distance", "Jukes-Cantor (JC69)", "Kimura 2-parameter (K2P)", "Poisson",
        ])
        XCTAssertEqual(MSADistanceModel.allCases.filter(\.isCorrectedDistance), [.jc69, .k2p, .poisson])
        XCTAssertEqual(MSADistanceModel.allCases.filter(\.isSimilarity), [.identity])
        XCTAssertEqual(MSAGapPolicy.allCases.map(\.rawValue), ["pairwise", "complete"])
        XCTAssertEqual(MSAGapPolicy.allCases.map(\.displayName), ["Pairwise deletion", "Complete deletion"])
        XCTAssertEqual(MSAGapPolicy.allCases.map(\.provenanceValue), ["pairwise-delete", "complete-delete"])
        XCTAssertEqual(MSADistanceOrder.allCases.map(\.rawValue), ["alignment", "average-linkage"])
        XCTAssertEqual(MSADistanceOrder.allCases.map(\.displayName), ["Alignment order", "Average linkage (UPGMA)"])
    }

    // MARK: - Complete deletion (P4)

    func testCompleteDeletionUsesTheSameSitesForEveryPair() throws {
        let sequences = ["ACGTA", "AC-TA", "ACGNA"]
        let pairwise = try matrix(sequences)
        XCTAssertEqual(pairwise.detail(row: 0, column: 2).comparableSites, 4)

        let complete = try matrix(sequences, MSADistanceOptions(gaps: .complete))
        for row in 0..<3 {
            for column in 0..<3 {
                let detail = complete.detail(row: row, column: column)
                XCTAssertEqual(detail.comparableSites, 3, "cell \(row),\(column)")
                XCTAssertEqual(detail.gapSkipped, 1)
                XCTAssertEqual(detail.ambiguitySkipped, 1)
            }
        }
        XCTAssertEqual(complete.values[0][1], 1.0, accuracy: 1e-12)
    }

    func testCompleteDeletionWithNoSitesLeftThrows() {
        XCTAssertThrowsError(try matrix(["A-", "-A"], MSADistanceOptions(gaps: .complete))) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .noComparableSitesAfterCompleteDeletion)
        }
        XCTAssertNoThrow(try matrix(["A-", "-A"]), "pairwise deletion gives nan, not an error")
    }

    // MARK: - Average linkage order (P5)

    func testAverageLinkageOrderBreaksTiesBySmallestThenLargestOriginalIndex() throws {
        // p-distances: d01 0.5, d02 0.25, d03 0.25, d12 0.25, d13 0.5, d23 0.25.
        // Four pairs tie at 0.25. (0,2) wins on min index 0 then max index 2. Then {0,2} and 3
        // tie-free at 0.25, then 1 joins. The child holding the smaller index goes first.
        let sequences = ["AAAA", "AACC", "AAAC", "AAAG"]
        let ordered = try matrix(sequences, MSADistanceOptions(order: .averageLinkage))
        XCTAssertEqual(ordered.recordIndices, [0, 2, 3, 1])
        XCTAssertEqual(ordered.names, ["r0", "r2", "r3", "r1"])

        let aligned = try matrix(sequences)
        XCTAssertEqual(ordered.tsv.split(separator: "\n").first, "row\tr0\tr2\tr3\tr1")
        for row in 0..<4 {
            for column in 0..<4 {
                let source = (ordered.recordIndices[row], ordered.recordIndices[column])
                XCTAssertEqual(ordered.values[row][column], aligned.values[source.0][source.1])
                XCTAssertEqual(
                    ordered.detail(row: row, column: column).comparableSites,
                    aligned.detail(row: source.0, column: source.1).comparableSites
                )
            }
        }
    }

    func testAverageLinkageUsesPDistanceWhateverTheModel() throws {
        let sequences = ["AAAA", "AACC", "AAAC", "AAAG"]
        for model in MSADistanceModel.models(for: .nucleotide) {
            let ordered = try matrix(sequences, MSADistanceOptions(model: model, order: .averageLinkage))
            XCTAssertEqual(ordered.recordIndices, [0, 2, 3, 1], "\(model)")
        }
    }

    func testAverageLinkageTreatsNoComparableSitesAsDistanceOne() throws {
        // r1 shares no site with anyone, so it joins last despite the identity model.
        let ordered = try matrix(["AAAA", "----", "AAAC"], MSADistanceOptions(order: .averageLinkage))
        XCTAssertEqual(ordered.recordIndices, [0, 2, 1])
    }

    func testAverageLinkageWithTwoRowsKeepsAlignmentOrder() throws {
        XCTAssertEqual(try matrix(["AC", "AG"], MSADistanceOptions(order: .averageLinkage)).recordIndices, [0, 1])
    }

    // MARK: - Alphabet and loading

    func testAlphabetFromManifestString() {
        XCTAssertEqual(MSASequenceAlphabet(manifestAlphabet: "protein"), .protein)
        XCTAssertEqual(MSASequenceAlphabet(manifestAlphabet: "dna"), .nucleotide)
        XCTAssertEqual(MSASequenceAlphabet(manifestAlphabet: "rna"), .nucleotide)
        XCTAssertEqual(MSASequenceAlphabet(manifestAlphabet: "unknown"), .nucleotide)
    }

    func testParseAlignedFASTAAndLoadFromBundle() throws {
        let parsed = MSAAlignedRecord.parseAlignedFASTA(">x desc\nAC GT\nac\n\n>y\n--GT\n")
        XCTAssertEqual(parsed, [
            MSAAlignedRecord(name: "x desc", sequence: "ACGTac"),
            MSAAlignedRecord(name: "y", sequence: "--GT"),
        ])
        XCTAssertTrue(MSAAlignedRecord.parseAlignedFASTA("").isEmpty)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-distance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("alignment.fasta")
        try ">seq1\nACGT\n>seq2\nA-GT\n>seq3\nACAT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)

        let loaded = try MSAAlignedRecord.loadPrimaryAlignment(of: bundleURL)
        XCTAssertEqual(loaded.map(\.name), ["seq1", "seq2", "seq3"])
        XCTAssertEqual(try MSASequenceAlphabet.load(fromBundle: bundleURL), .nucleotide)
        XCTAssertEqual(
            try MSADistanceMatrix(records: loaded, options: MSADistanceOptions()).tsv,
            try MSADistanceMatrix(records: records, options: MSADistanceOptions()).tsv
        )

        let proteinURL = tempDir.appendingPathComponent("protein.fasta")
        try ">p1\nMKVLEW\n>p2\nMKILEW\n".write(to: proteinURL, atomically: true, encoding: .utf8)
        let proteinBundleURL = tempDir.appendingPathComponent("protein.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: proteinURL, to: proteinBundleURL)
        XCTAssertEqual(try MSASequenceAlphabet.load(fromBundle: proteinBundleURL), .protein)
    }
}
