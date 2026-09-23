import Testing
@testable import LungfishCore

@Suite("UniqueReadStartCounter")
struct UniqueReadStartCounterTests {
    /// Builds a minimal SAM line with the fields the counter reads: FLAG,
    /// RNAME, POS (1-based), and CIGAR. Other fields are filled with
    /// placeholders since the counter never reads them.
    private func samLine(
        name: String = "read",
        flag: Int,
        rname: String = "chr1",
        pos1Based: Int,
        cigar: String
    ) -> String {
        "\(name)\t\(flag)\t\(rname)\t\(pos1Based)\t60\t\(cigar)\t*\t0\t0\tACGT\tIIII"
    }

    @Test("counts one unique read")
    func countsOneUniqueRead() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: samLine(flag: 0, pos1Based: 1, cigar: "4M"))
        #expect(counter.uniqueCount == 1)
        #expect(counter.recordCount == 1)
    }

    @Test("PERF-04: reads sharing position, end, and strand are deduplicated to one")
    func deduplicatesSamePositionEndStrand() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: samLine(name: "r1", flag: 0, pos1Based: 100, cigar: "50M"))
        counter.ingest(line: samLine(name: "r2", flag: 0, pos1Based: 100, cigar: "50M"))
        counter.ingest(line: samLine(name: "r3", flag: 0, pos1Based: 100, cigar: "50M"))
        #expect(counter.recordCount == 3)
        #expect(counter.uniqueCount == 1)
    }

    @Test("reads with the same start but different CIGAR (different end) are distinct")
    func differentEndIsDistinct() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: samLine(flag: 0, pos1Based: 100, cigar: "50M"))
        counter.ingest(line: samLine(flag: 0, pos1Based: 100, cigar: "60M"))
        #expect(counter.uniqueCount == 2)
    }

    @Test("same position and end but opposite strand are distinct")
    func differentStrandIsDistinct() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: samLine(flag: 0, pos1Based: 100, cigar: "50M"))       // forward
        counter.ingest(line: samLine(flag: 0x10, pos1Based: 100, cigar: "50M"))    // reverse
        #expect(counter.uniqueCount == 2)
    }

    @Test("unmapped reads are excluded")
    func excludesUnmapped() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: samLine(flag: 0x4, pos1Based: 1, cigar: "4M"))
        #expect(counter.uniqueCount == 0)
        #expect(counter.recordCount == 0)
    }

    @Test("header lines starting with @ are ignored")
    func ignoresHeaderLines() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: "@HD\tVN:1.6\tSO:coordinate")
        counter.ingest(line: "@SQ\tSN:chr1\tLN:1000")
        counter.ingest(line: samLine(flag: 0, pos1Based: 1, cigar: "4M"))
        #expect(counter.uniqueCount == 1)
    }

    @Test("CIGAR insertions and soft clips do not extend the reference end")
    func insertionsAndSoftClipsDoNotConsumeReference() {
        var counter = UniqueReadStartCounter()
        // 10M2I10M is 20 bases of reference consumed (2I does not count).
        counter.ingest(line: samLine(name: "r1", flag: 0, pos1Based: 1, cigar: "10M2I10M"))
        // 20M also consumes 20 bases of reference and starts at the same position,
        // so despite different CIGAR strings the two should collide (same end).
        counter.ingest(line: samLine(name: "r2", flag: 0, pos1Based: 1, cigar: "20M"))
        #expect(counter.uniqueCount == 1)
    }

    @Test("no cap: more than 100,000 distinct positions are all counted")
    func noCapOnManyUniquePositions() {
        // PERF-04's whole point: AlignedRead.deduplicatedReadCount(from:) via
        // fetchReads(maxReads: 100_000) can never report more than 100,000,
        // undercounting any contig with more true unique reads than that.
        // This streaming counter must not share that ceiling.
        var counter = UniqueReadStartCounter()
        let target = 100_050
        for position in 1...target {
            counter.ingest(line: samLine(flag: 0, pos1Based: position, cigar: "10M"))
        }
        #expect(counter.uniqueCount == target)
        #expect(counter.recordCount == target)
    }

    @Test("chunked ingestion across arbitrary split points matches line-by-line ingestion")
    func chunkedIngestionMatchesLineByLine() {
        let lines = (1...500).map { samLine(name: "r\($0)", flag: 0, pos1Based: $0, cigar: "10M") }
        let fullText = lines.joined(separator: "\n") + "\n"

        var lineByLine = UniqueReadStartCounter()
        for line in lines { lineByLine.ingest(line: line) }

        // Split the full text into arbitrary-sized chunks that do not align
        // with line boundaries, simulating 64 KB reads from a pipe.
        var chunked = UniqueReadStartCounter()
        var leftover = ""
        var index = fullText.startIndex
        let chunkSize = 37
        while index < fullText.endIndex {
            let end = fullText.index(index, offsetBy: chunkSize, limitedBy: fullText.endIndex) ?? fullText.endIndex
            chunked.ingest(chunk: String(fullText[index..<end]), leftover: &leftover)
            index = end
        }
        if !leftover.isEmpty {
            chunked.ingest(chunk: "", leftover: &leftover, isFinal: true)
        }

        #expect(chunked.uniqueCount == lineByLine.uniqueCount)
        #expect(chunked.recordCount == lineByLine.recordCount)
        #expect(chunked.uniqueCount == 500)
    }

    @Test("malformed lines are skipped without crashing")
    func skipsMalformedLines() {
        var counter = UniqueReadStartCounter()
        counter.ingest(line: "not\ta\tvalid\tsam\tline")
        counter.ingest(line: "")
        counter.ingest(line: samLine(flag: 0, pos1Based: 1, cigar: "4M"))
        #expect(counter.uniqueCount == 1)
    }
}
