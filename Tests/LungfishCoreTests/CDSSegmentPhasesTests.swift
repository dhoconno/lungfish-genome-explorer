import Testing
@testable import LungfishCore

@Suite("CDSSegmentPhases")
struct CDSSegmentPhasesTests {
    @Test("single interval is phase 0")
    func singleIntervalIsPhaseZero() {
        let result = CDSSegmentPhases.compute(
            intervals: [.init(start: 100, end: 400)],
            strand: "+"
        )
        #expect(result.count == 1)
        #expect(result[0].phase == 0)
    }

    @Test("SARS-CoV-2 ORF1ab -1 frameshift: both segments are phase 0")
    func orf1abFrameshiftBothSegmentsPhaseZero() {
        // MT192765.1 ORF1ab: CDS 259..13461 and CDS 13461..21548 (1-based,
        // inclusive), i.e. 0-based half-open 258..13461 and 13460..21548.
        // Segment 1 length = 13461 - 258 = 13203, divisible by 3, so segment
        // 2 also starts in-frame (phase 0). This is the real-world case that
        // motivated this helper: NCBI's own annotation has phase 0 on both
        // segments of the ribosomal-slippage CDS.
        let segment1 = CDSSegmentPhases.Interval(start: 258, end: 13461)
        let segment2 = CDSSegmentPhases.Interval(start: 13460, end: 21548)
        #expect(segment1.length % 3 == 0)

        let result = CDSSegmentPhases.compute(intervals: [segment1, segment2], strand: "+")
        #expect(result.count == 2)
        #expect(result[0].interval == segment1)
        #expect(result[0].phase == 0)
        #expect(result[1].interval == segment2)
        #expect(result[1].phase == 0)
    }

    @Test("plus-strand segment whose upstream length is not a multiple of 3 gets a nonzero phase")
    func plusStrandNonMultipleOfThreeGivesNonzeroPhase() {
        // First segment length 10 -> 10 % 3 == 1, so 2 more bases are needed
        // to complete the codon that started in segment 1. Phase = (3 - 1) % 3 = 2.
        let segment1 = CDSSegmentPhases.Interval(start: 0, end: 10)
        let segment2 = CDSSegmentPhases.Interval(start: 20, end: 40)

        let result = CDSSegmentPhases.compute(intervals: [segment1, segment2], strand: "+")
        #expect(result[0].phase == 0)
        #expect(result[1].phase == 2)
    }

    @Test("minus-strand transcription order is descending genomic order")
    func minusStrandTranscriptionOrderDescending() {
        // On the minus strand, transcription starts at the highest-coordinate
        // segment. Segment B (genomically last) is transcribed first, so it
        // is phase 0. Segment A follows: B's length is 10 -> phase (3-1)%3 = 2.
        let segmentA = CDSSegmentPhases.Interval(start: 0, end: 20)   // genomically first, transcribed last
        let segmentB = CDSSegmentPhases.Interval(start: 30, end: 40)  // genomically last, transcribed first (len 10)

        let result = CDSSegmentPhases.compute(intervals: [segmentA, segmentB], strand: "-")
        // Result stays sorted by genomic start ascending.
        #expect(result[0].interval == segmentA)
        #expect(result[0].phase == 2)
        #expect(result[1].interval == segmentB)
        #expect(result[1].phase == 0)
    }

    @Test("empty input returns empty output")
    func emptyInputReturnsEmpty() {
        #expect(CDSSegmentPhases.compute(intervals: [], strand: "+").isEmpty)
    }

    @Test("unsorted input intervals are sorted into genomic order in the result")
    func unsortedInputIsSortedInResult() {
        let later = CDSSegmentPhases.Interval(start: 100, end: 130)
        let earlier = CDSSegmentPhases.Interval(start: 0, end: 30)
        let result = CDSSegmentPhases.compute(intervals: [later, earlier], strand: "+")
        #expect(result.map(\.interval.start) == [0, 100])
    }
}
