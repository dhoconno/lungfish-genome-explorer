import XCTest
@testable import LungfishApp
import LungfishWorkflow

final class FASTQStatisticsServiceTests: XCTestCase {
    func testComputeAggregatesMultiFileFASTQInputs() async throws {
        let fixture = try FASTQStatisticsToolFixture()
        defer { fixture.cleanup() }

        let chunkA = fixture.root.appendingPathComponent("chunk-a.fastq")
        let chunkB = fixture.root.appendingPathComponent("chunk-b.fastq")
        try fixture.writeFASTQ(
            [
                ("read-1", "ACGT"),
                ("read-2", "ACGTAC"),
            ],
            to: chunkA
        )
        try fixture.writeFASTQ(
            [
                ("read-3", "AC"),
            ],
            to: chunkB
        )

        let result = try await FASTQStatisticsService.compute(
            for: [chunkA, chunkB],
            runner: fixture.runner
        )

        XCTAssertEqual(result.statistics.readCount, 3)
        XCTAssertEqual(result.statistics.baseCount, 12)
        XCTAssertEqual(result.statistics.minReadLength, 2)
        XCTAssertEqual(result.statistics.maxReadLength, 6)
        XCTAssertEqual(result.statistics.meanReadLength, 4.0, accuracy: 0.001)
        XCTAssertEqual(result.statistics.medianReadLength, 4)
        XCTAssertEqual(result.statistics.n50ReadLength, 6)
        XCTAssertEqual(result.statistics.readLengthHistogram, [2: 1, 4: 1, 6: 1])
        XCTAssertEqual(result.scannedReadCount, 3)
    }
}

private final class FASTQStatisticsToolFixture {
    let root: URL
    let runner: NativeToolRunner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQStatisticsServiceTests-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let binURL = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/seqkit/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let seqkitURL = binURL.appendingPathComponent("seqkit")
        try Self.seqkitScript.write(to: seqkitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seqkitURL.path)
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFASTQ(_ records: [(String, String)], to url: URL) throws {
        let text = records.flatMap { id, sequence in
            ["@\(id)", sequence, "+", String(repeating: "I", count: sequence.count)]
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let seqkitScript = """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "seqkit v2.13.0"
      exit 0
    fi
    if [ "$1" = "stats" ]; then
      shift
      printf 'file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tQ20(%%)\tQ30(%%)\tAvgQual\tGC(%%)\\n'
      for arg in "$@"; do
        case "$arg" in
          -*) continue ;;
        esac
        awk -v file="$arg" '
          BEGIN { n = 0; sum = 0; min = 0; max = 0; gc = 0 }
          NR % 4 == 2 {
            len = length($0)
            n += 1
            sum += len
            if (min == 0 || len < min) min = len
            if (len > max) max = len
            seq = toupper($0)
            for (i = 1; i <= len; i++) {
              base = substr(seq, i, 1)
              if (base == "G" || base == "C") gc += 1
            }
          }
          END {
            avg = n > 0 ? sum / n : 0
            gcPct = sum > 0 ? gc * 100 / sum : 0
            printf "%s\\tFASTQ\\tDNA\\t%d\\t%d\\t%d\\t%.6f\\t%d\\t100.000000\\t100.000000\\t40.000000\\t%.6f\\n", file, n, sum, min, avg, max, gcPct
          }
        ' "$arg"
      done
      exit 0
    fi
    exit 1
    """
}
