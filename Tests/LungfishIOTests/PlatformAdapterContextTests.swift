import XCTest
@testable import LungfishIO

final class PlatformAdapterContextTests: XCTestCase {

    // MARK: - Reverse Complement Helper

    func testReverseComplementSimple() {
        XCTAssertEqual(PlatformAdapters.reverseComplement("ACGT"), "ACGT") // palindrome
    }

    func testReverseComplementAsymmetric() {
        XCTAssertEqual(PlatformAdapters.reverseComplement("AACG"), "CGTT")
    }

    func testReverseComplementWithN() {
        XCTAssertEqual(PlatformAdapters.reverseComplement("NACG"), "CGTN")
    }

    func testReverseComplementEmptyString() {
        XCTAssertEqual(PlatformAdapters.reverseComplement(""), "")
    }

    func testReverseComplementUnknownBase() {
        // Non-ACGTN characters pass through unchanged
        XCTAssertEqual(PlatformAdapters.reverseComplement("AXG"), "CXT")
    }

    // MARK: - Adapter Sequence Validation

    func testAdapterSequencesAreValidDNA() {
        let validBases = Set("ACGTacgt")
        let sequences: [(String, String)] = [
            ("ontYAdapterTop", PlatformAdapters.ontYAdapterTop),
            ("ontYAdapterBottom", PlatformAdapters.ontYAdapterBottom),
            ("ontNativeOuterFlank5", PlatformAdapters.ontNativeOuterFlank5),
            ("ontNativeOuterFlank3", PlatformAdapters.ontNativeOuterFlank3),
            ("ontNativeBarcodeFlank5", PlatformAdapters.ontNativeBarcodeFlank5),
            ("ontNativeBarcodeFlank3", PlatformAdapters.ontNativeBarcodeFlank3),
            ("ontTransposaseME", PlatformAdapters.ontTransposaseME),
            ("ontTransposaseMErc", PlatformAdapters.ontTransposaseMErc),
            ("illuminaUniversal", PlatformAdapters.illuminaUniversal),
            ("truseqR1", PlatformAdapters.truseqR1),
            ("truseqR2", PlatformAdapters.truseqR2),
            ("nexteraR1", PlatformAdapters.nexteraR1),
            ("nexteraR2", PlatformAdapters.nexteraR2),
            ("mgiR1", PlatformAdapters.mgiR1),
            ("mgiR2", PlatformAdapters.mgiR2),
        ]
        for (name, seq) in sequences {
            XCTAssertFalse(seq.isEmpty, "\(name) should not be empty")
            for char in seq {
                XCTAssertTrue(validBases.contains(char), "\(name) has invalid base '\(char)'")
            }
        }
    }

    func testONTFlankSequencesAreReverseComplements() {
        let rc = PlatformAdapters.reverseComplement(PlatformAdapters.ontNativeBarcodeFlank5)
        XCTAssertEqual(rc, PlatformAdapters.ontNativeBarcodeFlank3)
    }

    func testONTOuterFlankSequencesAreReverseComplements() {
        let rc = PlatformAdapters.reverseComplement(PlatformAdapters.ontNativeOuterFlank5)
        XCTAssertEqual(rc, PlatformAdapters.ontNativeOuterFlank3)
    }

    func testONTTransposaseMEAreReverseComplements() {
        let rc = PlatformAdapters.reverseComplement(PlatformAdapters.ontTransposaseME)
        XCTAssertEqual(rc, PlatformAdapters.ontTransposaseMErc)
    }

    // MARK: - ONT Native Barcoding Context

    func testONTNativeContextFivePrime() {
        let ctx = ONTNativeAdapterContext()
        let barcode = "AAGAAAGTTGTCGGTGTCTTTGTG"
        let result = ctx.fivePrimeSpec(barcodeSequence: barcode)
        let expected = PlatformAdapters.ontYAdapterTop
            + PlatformAdapters.ontNativeOuterFlank5
            + barcode
        XCTAssertEqual(result, expected)
    }

    func testONTNativeContextThreePrime() {
        let ctx = ONTNativeAdapterContext()
        let barcode = "AAGAAAGTTGTCGGTGTCTTTGTG"
        let result = ctx.threePrimeSpec(barcodeSequence: barcode)
        let expected = PlatformAdapters.reverseComplement(barcode)
            + PlatformAdapters.ontNativeOuterFlank3
            + PlatformAdapters.ontYAdapterBottom
        XCTAssertEqual(result, expected)
    }

    func testONTNativeContextLinked() {
        let ctx = ONTNativeAdapterContext()
        let result = ctx.linkedSpec(barcodeSequence: "AAGAAAGTTGTCGGTGTCTTTGTG")
        XCTAssertTrue(result.contains("..."), "Linked spec must contain '...' separator")
        let parts = result.components(separatedBy: "...")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix(PlatformAdapters.ontYAdapterTop))
        XCTAssertTrue(parts[1].hasSuffix(PlatformAdapters.ontYAdapterBottom))
    }

    func testONTNativeContextUppercasesBarcode() {
        let ctx = ONTNativeAdapterContext()
        let result = ctx.fivePrimeSpec(barcodeSequence: "aagaaagttgtcggtgtctttgtg")
        XCTAssertTrue(result.contains("AAGAAAGTTGTCGGTGTCTTTGTG"))
    }

    // MARK: - ONT Rapid Barcoding Context

    func testONTRapidContextFivePrime() {
        let ctx = ONTRapidAdapterContext()
        let result = ctx.fivePrimeSpec(barcodeSequence: "AAGAAAGTTGTCGGTGTCTTTGTG")
        XCTAssertTrue(result.hasPrefix(PlatformAdapters.ontRapidAdapter))
        XCTAssertTrue(result.hasSuffix(PlatformAdapters.ontTransposaseME))
    }

    func testONTRapidContextThreePrime() {
        let ctx = ONTRapidAdapterContext()
        let barcode = "AAGAAAGTTGTCGGTGTCTTTGTG"
        let result = ctx.threePrimeSpec(barcodeSequence: barcode)
        XCTAssertTrue(result.hasPrefix(PlatformAdapters.ontTransposaseMErc))
        XCTAssertTrue(result.contains(PlatformAdapters.reverseComplement(barcode)))
    }

    func testONTRapidContextLinked() {
        let ctx = ONTRapidAdapterContext()
        let result = ctx.linkedSpec(barcodeSequence: "AAGAAAGTTGTCGGTGTCTTTGTG")
        XCTAssertTrue(result.contains("..."))
    }

    // MARK: - PacBio Context

    func testPacBioContextFivePrime() {
        let ctx = PacBioAdapterContext()
        let result = ctx.fivePrimeSpec(barcodeSequence: "CACATATCAGAGTGCG")
        XCTAssertEqual(result, "CACATATCAGAGTGCG")
    }

    func testPacBioContextThreePrime() {
        let ctx = PacBioAdapterContext()
        let result = ctx.threePrimeSpec(barcodeSequence: "CACATATCAGAGTGCG")
        XCTAssertEqual(result, PlatformAdapters.reverseComplement("CACATATCAGAGTGCG"))
    }

    func testPacBioContextLinked() {
        let ctx = PacBioAdapterContext()
        let barcode = "CACATATCAGAGTGCG"
        let result = ctx.linkedSpec(barcodeSequence: barcode)
        XCTAssertEqual(result, "\(barcode)...\(PlatformAdapters.reverseComplement(barcode))")
    }

    // MARK: - Illumina TruSeq Context

    func testIlluminaTruSeqContextFivePrime() {
        let ctx = IlluminaTruSeqAdapterContext()
        XCTAssertEqual(ctx.fivePrimeSpec(barcodeSequence: "ATCACG"), "")
    }

    func testIlluminaTruSeqContextThreePrime() {
        let ctx = IlluminaTruSeqAdapterContext()
        XCTAssertEqual(ctx.threePrimeSpec(barcodeSequence: "ATCACG"), PlatformAdapters.truseqR1)
    }

    func testIlluminaTruSeqContextLinked() {
        let ctx = IlluminaTruSeqAdapterContext()
        XCTAssertEqual(ctx.linkedSpec(barcodeSequence: "ATCACG"), PlatformAdapters.truseqR1)
    }

    // MARK: - Illumina Nextera Context

    func testIlluminaNexteraContextThreePrime() {
        let ctx = IlluminaNexteraAdapterContext()
        XCTAssertEqual(ctx.threePrimeSpec(barcodeSequence: "ATCACG"), PlatformAdapters.nexteraR1)
    }

    // MARK: - MGI Context

    func testMGIContextThreePrime() {
        let ctx = MGIAdapterContext()
        XCTAssertEqual(ctx.threePrimeSpec(barcodeSequence: "ATCACG"), PlatformAdapters.mgiR1)
    }

    func testMGIContextFivePrime() {
        let ctx = MGIAdapterContext()
        XCTAssertEqual(ctx.fivePrimeSpec(barcodeSequence: "ATCACG"), "")
    }

    // MARK: - Bare Context

    func testBareContextFivePrime() {
        let ctx = BareAdapterContext()
        XCTAssertEqual(ctx.fivePrimeSpec(barcodeSequence: "acgt"), "ACGT")
    }

    func testBareContextThreePrime() {
        let ctx = BareAdapterContext()
        XCTAssertEqual(ctx.threePrimeSpec(barcodeSequence: "ACGT"), "ACGT") // palindrome
    }

    func testBareContextLinked() {
        let ctx = BareAdapterContext()
        let result = ctx.linkedSpec(barcodeSequence: "AACG")
        XCTAssertEqual(result, "AACG...CGTT")
    }

    // MARK: - Factory

    func testONTNativeKitReturnsNativeContext() {
        let ctx = SequencingPlatform.oxfordNanopore.adapterContext(kitType: .nativeBarcoding)
        XCTAssertTrue(ctx is ONTNativeAdapterContext)
    }

    func testONTRapidKitReturnsRapidContext() {
        let ctx = SequencingPlatform.oxfordNanopore.adapterContext(kitType: .rapidBarcoding)
        XCTAssertTrue(ctx is ONTRapidAdapterContext)
    }

    func testONTPCRBarcodingReturnsNativeContext() {
        let ctx = SequencingPlatform.oxfordNanopore.adapterContext(kitType: .pcrBarcoding)
        XCTAssertTrue(ctx is ONTNativeAdapterContext)
    }

    func testONTSixteenSReturnsNativeContext() {
        let ctx = SequencingPlatform.oxfordNanopore.adapterContext(kitType: .sixteenS)
        XCTAssertTrue(ctx is ONTNativeAdapterContext)
    }

    func testPacBioReturnsPacBioContext() {
        let ctx = SequencingPlatform.pacbio.adapterContext(kitType: .pacbioStandard)
        XCTAssertTrue(ctx is PacBioAdapterContext)
    }

    func testIlluminaTruSeqDefault() {
        let ctx = SequencingPlatform.illumina.adapterContext(kitType: .truseq)
        XCTAssertTrue(ctx is IlluminaTruSeqAdapterContext)
    }

    func testIlluminaNextera() {
        let ctx = SequencingPlatform.illumina.adapterContext(kitType: .nextera)
        XCTAssertTrue(ctx is IlluminaNexteraAdapterContext)
    }

    func testElementReturnsTruSeqContext() {
        let ctx = SequencingPlatform.element.adapterContext()
        XCTAssertTrue(ctx is IlluminaTruSeqAdapterContext)
    }

    func testUltimaReturnsTruSeqContext() {
        let ctx = SequencingPlatform.ultima.adapterContext()
        XCTAssertTrue(ctx is IlluminaTruSeqAdapterContext)
    }

    func testMGIReturnsMGIContext() {
        let ctx = SequencingPlatform.mgi.adapterContext()
        XCTAssertTrue(ctx is MGIAdapterContext)
    }

    func testUnknownReturnsBareContext() {
        let ctx = SequencingPlatform.unknown.adapterContext()
        XCTAssertTrue(ctx is BareAdapterContext)
    }

    // MARK: - BarcodeKitType

    func testBarcodeKitTypeCaseCount() {
        XCTAssertEqual(BarcodeKitType.allCases.count, 9)
    }

    func testBarcodeKitTypeCodableRoundTrip() throws {
        for kitType in BarcodeKitType.allCases {
            let data = try JSONEncoder().encode(kitType)
            let decoded = try JSONDecoder().decode(BarcodeKitType.self, from: data)
            XCTAssertEqual(decoded, kitType)
        }
    }

    // MARK: - ReadDirection

    func testReadDirectionCases() {
        XCTAssertEqual(ReadDirection.allCases.count, 2)
        XCTAssertEqual(ReadDirection.read1.rawValue, "read1")
        XCTAssertEqual(ReadDirection.read2.rawValue, "read2")
    }

    // MARK: - R2 Adapter Direction Support

    func testTruSeqR1VsR2() {
        let ctx = IlluminaTruSeqAdapterContext()
        let r1 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read1)
        let r2 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read2)
        XCTAssertEqual(r1, PlatformAdapters.truseqR1)
        XCTAssertEqual(r2, PlatformAdapters.truseqR2)
        XCTAssertNotEqual(r1, r2)
    }

    func testNexteraR1VsR2() {
        let ctx = IlluminaNexteraAdapterContext()
        let r1 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read1)
        let r2 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read2)
        XCTAssertEqual(r1, PlatformAdapters.nexteraR1)
        XCTAssertEqual(r2, PlatformAdapters.nexteraR2)
        XCTAssertNotEqual(r1, r2)
    }

    func testMGIR1VsR2() {
        let ctx = MGIAdapterContext()
        let r1 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read1)
        let r2 = ctx.threePrimeSpec(barcodeSequence: "", readDirection: .read2)
        XCTAssertEqual(r1, PlatformAdapters.mgiR1)
        XCTAssertEqual(r2, PlatformAdapters.mgiR2)
        XCTAssertNotEqual(r1, r2)
    }

    func testLongReadContextsIgnoreReadDirection() {
        // Long-read platforms return the same adapter for both directions
        let ontCtx = ONTNativeAdapterContext()
        let bc = "AAGAAAGTTGTCGGTGTCTTTGTG"
        XCTAssertEqual(
            ontCtx.threePrimeSpec(barcodeSequence: bc, readDirection: .read1),
            ontCtx.threePrimeSpec(barcodeSequence: bc, readDirection: .read2)
        )

        let pbCtx = PacBioAdapterContext()
        XCTAssertEqual(
            pbCtx.threePrimeSpec(barcodeSequence: bc, readDirection: .read1),
            pbCtx.threePrimeSpec(barcodeSequence: bc, readDirection: .read2)
        )
    }

    func testDefaultReadDirectionDelegatesToThreePrimeSpec() {
        // BareAdapterContext uses the default protocol extension
        let ctx = BareAdapterContext()
        let bc = "ACGT"
        XCTAssertEqual(
            ctx.threePrimeSpec(barcodeSequence: bc, readDirection: .read1),
            ctx.threePrimeSpec(barcodeSequence: bc)
        )
        XCTAssertEqual(
            ctx.threePrimeSpec(barcodeSequence: bc, readDirection: .read2),
            ctx.threePrimeSpec(barcodeSequence: bc)
        )
    }

    // MARK: - SMRTbell Contamination Detection

    func testSMRTbellDetectionCleanSequence() {
        let cleanSeq = "AAGAAAGTTGTCGGTGTCTTTGTGCAGCACCTAATGTACTTCGTTCAGTTAC"
        XCTAssertNil(PlatformAdapters.detectSMRTbellContamination(in: cleanSeq))
    }

    func testSMRTbellDetectionV3Forward() {
        // Embed SMRTbell v3 prefix in a read
        let contaminated = "ATCGATCG" + String(PlatformAdapters.smrtbellV3.prefix(16)) + "GCTAGCTA"
        let result = PlatformAdapters.detectSMRTbellContamination(in: contaminated)
        XCTAssertEqual(result, "SMRTbell v3")
    }

    func testSMRTbellDetectionV2Forward() {
        let contaminated = "ATCGATCG" + String(PlatformAdapters.smrtbellV2.prefix(16)) + "GCTAGCTA"
        let result = PlatformAdapters.detectSMRTbellContamination(in: contaminated)
        XCTAssertEqual(result, "SMRTbell v2")
    }

    func testSMRTbellDetectionV1Forward() {
        let contaminated = "ATCGATCG" + String(PlatformAdapters.smrtbellV1.prefix(16)) + "GCTAGCTA"
        let result = PlatformAdapters.detectSMRTbellContamination(in: contaminated)
        XCTAssertEqual(result, "SMRTbell v1")
    }

    func testSMRTbellDetectionReverseComplement() {
        let rcPrefix = String(PlatformAdapters.reverseComplement(PlatformAdapters.smrtbellV1).prefix(16))
        let contaminated = "ATCGATCG" + rcPrefix + "GCTAGCTA"
        let result = PlatformAdapters.detectSMRTbellContamination(in: contaminated)
        XCTAssertEqual(result, "SMRTbell v1")
    }

    func testSMRTbellDetectionCaseInsensitive() {
        let lower = String(PlatformAdapters.smrtbellV2.prefix(16)).lowercased()
        let contaminated = "atcgatcg" + lower + "gctagcta"
        let result = PlatformAdapters.detectSMRTbellContamination(in: contaminated)
        XCTAssertEqual(result, "SMRTbell v2")
    }

    func testSMRTbellAdaptersArray() {
        XCTAssertEqual(PlatformAdapters.smrtbellAdapters.count, 3)
        XCTAssertEqual(PlatformAdapters.smrtbellAdapters[0].label, "SMRTbell v3")
        XCTAssertEqual(PlatformAdapters.smrtbellAdapters[1].label, "SMRTbell v2")
        XCTAssertEqual(PlatformAdapters.smrtbellAdapters[2].label, "SMRTbell v1")
    }

    // MARK: - AdapterQCResult

    func testAdapterQCResultNoContamination() {
        let result = AdapterQCResult(readsScanned: 1000, contaminatedReadCount: 0, hitsByAdapter: [:])
        XCTAssertEqual(result.contaminationRate, 0)
        XCTAssertFalse(result.isWarning)
        XCTAssertTrue(result.summary.contains("No adapter contamination"))
    }

    func testAdapterQCResultWithContamination() {
        let result = AdapterQCResult(
            readsScanned: 1000,
            contaminatedReadCount: 5,
            hitsByAdapter: ["SMRTbell v3": 3, "SMRTbell v1": 2]
        )
        XCTAssertEqual(result.contaminationRate, 0.005, accuracy: 0.0001)
        XCTAssertTrue(result.isWarning)
        XCTAssertTrue(result.summary.contains("5/1000"))
        XCTAssertTrue(result.summary.contains("0.50%"))
    }

    func testAdapterQCResultZeroReads() {
        let result = AdapterQCResult(readsScanned: 0, contaminatedReadCount: 0, hitsByAdapter: [:])
        XCTAssertEqual(result.contaminationRate, 0)
        XCTAssertFalse(result.isWarning)
    }

    func testAdapterQCResultBelowWarningThreshold() {
        // 1 in 10000 = 0.01% < 0.1% threshold
        let result = AdapterQCResult(readsScanned: 10000, contaminatedReadCount: 1, hitsByAdapter: ["SMRTbell v3": 1])
        XCTAssertEqual(result.contaminationRate, 0.0001, accuracy: 0.00001)
        XCTAssertFalse(result.isWarning)
    }

    func testAdapterQCResultCodableRoundTrip() throws {
        let result = AdapterQCResult(
            readsScanned: 500,
            contaminatedReadCount: 3,
            hitsByAdapter: ["SMRTbell v3": 2, "SMRTbell v2": 1]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AdapterQCResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
