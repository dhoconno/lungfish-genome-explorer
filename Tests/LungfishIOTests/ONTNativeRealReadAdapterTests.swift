import XCTest
@testable import LungfishIO

/// The ONT native-barcoding adapter construct checked against real reads.
final class ONTNativeRealReadAdapterTests: XCTestCase {
    /// Three reads from ENA PRJEB62796 (SQK-NBD114-96, run folders barcode85,
    /// barcode89 and barcode91), untrimmed as the submitters uploaded them.
    static let realNBD114Reads: [(barcodeID: String, sequence: String)] = [
        ("NB85", "TGTACTTCGTTCAGTTACGTATTGCTGGTGCTGAACGGAGGAGTTAGTTGGATGATCTTAACCTTTCTGTTGGTGCTGATACCTTGGTTCAAGGCAGGCTGTTCTGTAATCGATAAACCCCGTTCTGCAAATAGAAAACAGGAAAGAAGATAGAGCGACAGGCAAGTAGGTTAAAGATCATCCAACTAACTCCTCCGTTCAGCACCAACT"),
        ("NB89", "GCTGTACTTCGTTCAGTTACGTATTGCTGGTGCTGACAGCATCAATGTTTGGCTAGTTGTTAACCTACTTGCCTGTCGCTCTATCTTCGAGCAGCAACAAGAAAGCAGCACCAACTGAACATGCTCCTATTCAGGCAGAGACAGAAAGTGGACGTACTGTAGAAGCTGGCCATTACGTAGTTTTGGCAGCGATCACCAGTAAACTCATTTGGGCACTTTCTTGGTTTTGGACTTTCATGGGCACATTCTCAGTACATCTTACTCCAGTGAATCCAGGTTGGCACTTGCACAAGTATCTCGAGGGTTTGAAGGTCTTTCACCATGAAGCACTCCCCTCCATTCACACAGAAAGTTTTCTCCTTCTCCGCACATTTTACAAGATGGCTTGTCCCAGTGGTGGATGTAGATGTAGATGAGAAAAGTATTTGCTCCCTCTGTGGATACTGATGTTCTAATGGGAGACTCTGAAGACACATATGCTCCTTCAGTTGAGGCTGGCATACCGAGAGAGTGATGATCTCTGAAAAAAAGGTGATAGGACATTATGATATATAAACAGGAGGCCGGGAGCAGGTACCACAGCCTGCCTTGGAACTAAGCAATATCAGCACCAGCAAAGGAAAGGTTAACAACTAGCCAAACATTGATGCTGTCAGCACCAGCAATACG"),
        ("NB91", "GCGTACTTCGTTCAGTTACGTATTGGTGCTGGGCTCCATAGGAACTCACGCTACTTTAACCTACTTGCCTGTCGCTCTATCTTCGATGCAGCAACAAGAAAACAGCACCAACTGAGCATGCTCCTATTCAGGCAGAGACAGAAGAGAGTGGACGTACTGTAGAAGCTGGCCATTACGTAGTTTTGGCAGCGATCACCAGTAAACTCATTTGGGCACTTTTCTTGGTTTTGGACTTTCGTGGGCACATTCTCAGTACATCTTGCTCAGTGAATCCAAGGTTGGCACTTGCACAAGTATCTCGAGGGGTTTGAAAGGTCTTTCACCATGAAGCACTCCCCTCCATTCACACAGAAAGTTTTCTCCTTCTCCGCACATTTTACAAGATGGCTTGTCCCAGTGGTGGATGTAGATGTAGATGAAGAAGTATTTGCTCCTTCTGTGGATACTGATATTCTAATGGGAGACTCTGAAGACACATGCTCCTTCAGTTGAGGCTGGCATACCAGTGATGACCTCTGAAAAAAAAAAGGTGATAGGACATTATGATATATAAACGGGGCGGGAGCAGGTACTACAGCCTGCGGAACTAAGCAATATCAGCACCAACAGAAAGGTTAAAGTAGCGTGAGTTCCTATGGAGCCCAGCACCAACAATACATGTAT"),
    ]

    private func hamming(_ a: Substring, _ b: String) -> Int {
        zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
    }

    /// The published barcode sits at the 5' end in its published orientation
    /// between `GGTGCTG` and `TTAACCTT`, and reverse-complemented at the 3' end
    /// between `AAGGTTAA` and `CAGCACC`. That is the arrangement the adapter
    /// context must build; the earlier construct was its reverse complement and
    /// assigned about nothing on these runs.
    func testONTNativeSpecsMatchRealNBD114ReadArrangement() throws {
        let kit = BarcodeKitRegistry.ontNativeBarcoding96
        let ctx = ONTNativeAdapterContext()
        for read in Self.realNBD114Reads {
            let barcode = try XCTUnwrap(kit.barcodes.first(where: { $0.id == read.barcodeID })).i7Sequence
            let rc = PlatformAdapters.reverseComplement(barcode)
            let sequence = read.sequence

            let five = ctx.fivePrimeSpec(barcodeSequence: barcode)
            XCTAssertTrue(five.hasSuffix("GGTGCTG" + barcode + "TTAACCTT"), read.barcodeID)
            XCTAssertTrue(five.hasPrefix(PlatformAdapters.ontYAdapterTop), read.barcodeID)
            let three = ctx.threePrimeSpec(barcodeSequence: barcode)
            XCTAssertTrue(three.hasPrefix("AAGGTTAA" + rc + "CAGCACC"), read.barcodeID)
            XCTAssertTrue(three.hasSuffix(PlatformAdapters.ontYAdapterBottom), read.barcodeID)

            let start = try XCTUnwrap(sequence.range(of: barcode), "\(read.barcodeID) barcode at 5'")
            let before = sequence[sequence.index(start.lowerBound, offsetBy: -7)..<start.lowerBound]
            let after = sequence[start.upperBound..<sequence.index(start.upperBound, offsetBy: 8)]
            // Basecalled flanks carry the odd error, so each flank must be closer
            // to the arrangement the context builds than to the reverse-complement
            // arrangement the earlier construct assumed (AAGGTTAA ... CAGCACCT).
            XCTAssertLessThan(hamming(before, PlatformAdapters.ontNativeOuterFlank5), hamming(before, "AGGTTAA"), "\(read.barcodeID) 5' outer flank")
            XCTAssertLessThan(hamming(after, PlatformAdapters.ontNativeBarcodeFlank5), hamming(after, "CAGCACCT"), "\(read.barcodeID) 5' inner flank")

            let end = try XCTUnwrap(sequence.range(of: rc, options: .backwards), "\(read.barcodeID) rc barcode at 3'")
            let beforeEnd = sequence[sequence.index(end.lowerBound, offsetBy: -8)..<end.lowerBound]
            let afterEnd = sequence[end.upperBound..<sequence.index(end.upperBound, offsetBy: 7)]
            XCTAssertLessThan(hamming(beforeEnd, PlatformAdapters.ontNativeBarcodeFlank3), hamming(beforeEnd, "AGGTGCTG"), "\(read.barcodeID) 3' inner flank")
            XCTAssertLessThan(hamming(afterEnd, PlatformAdapters.ontNativeOuterFlank3), hamming(afterEnd, "TTAACCT"), "\(read.barcodeID) 3' outer flank")
        }
    }

    func testONTNativeFlanksAreReverseComplementsOfEachOther() {
        XCTAssertEqual(PlatformAdapters.reverseComplement(PlatformAdapters.ontNativeOuterFlank5), PlatformAdapters.ontNativeOuterFlank3)
        XCTAssertEqual(PlatformAdapters.reverseComplement(PlatformAdapters.ontNativeBarcodeFlank5), PlatformAdapters.ontNativeBarcodeFlank3)
        XCTAssertEqual(PlatformAdapters.ontNativeOuterFlank5, "GGTGCTG")
        XCTAssertEqual(PlatformAdapters.ontNativeBarcodeFlank5, "TTAACCTT")
    }
}
