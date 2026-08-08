import XCTest
@testable import LungfishWorkflow

final class MappingSummaryBuilderTests: XCTestCase {

    func testBuildSummariesCombinesCoverageAndIdentityMetrics() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        chr1\t1\t1000\t3\t800\t80.0\t6.5\t30.0\t43.3
        chr2\t1\t500\t1\t100\t20.0\t0.4\t25.0\t10.0
        """

        let viewOutput = """
        read1\t0\tchr1\t1\t60\t100M\t*\t0\t0\tACGT\t*\tNM:i:0
        read2\t0\tchr1\t10\t50\t50M10I40M\t*\t0\t0\tACGT\t*\tNM:i:5
        read3\t0\tchr1\t20\t20\t90M10S\t*\t0\t0\tACGT\t*\tNM:i:2
        read4\t0\tchr2\t30\t10\t40M10I\t*\t0\t0\tACGT\t*\tNM:i:1
        """

        let summaries = try MappingSummaryBuilder.buildSummaries(
            coverageOutput: coverageOutput,
            viewOutput: viewOutput,
            totalReads: 10
        )

        XCTAssertEqual(summaries.map(\.contigName), ["chr1", "chr2"])
        XCTAssertEqual(summaries[0].contigLength, 1000)
        XCTAssertEqual(summaries[0].mappedReads, 3)
        XCTAssertEqual(summaries[0].mappedReadPercent, 30.0, accuracy: 0.001)
        XCTAssertEqual(summaries[0].coverageBreadth, 0.8, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].meanDepth, 6.5, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].medianMAPQ, 50.0, accuracy: 0.001)
        XCTAssertEqual(summaries[0].meanIdentity, 283.0 / 290.0, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].coverageBreadth, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].meanIdentity, 49.0 / 50.0, accuracy: 0.0001)
    }

    func testBuildSummariesNormalizesLegacyCoverageFractions() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        chr1\t1\t100\t2\t50\t0.5\t4.0\t30.0\t40.0
        """

        let viewOutput = """
        read1\t0\tchr1\t1\t40\t50M\t*\t0\t0\tACGT\t*\tNM:i:0
        read2\t0\tchr1\t10\t40\t50M\t*\t0\t0\tACGT\t*\tNM:i:1
        """

        let summary = try XCTUnwrap(
            MappingSummaryBuilder.buildSummaries(
                coverageOutput: coverageOutput,
                viewOutput: viewOutput,
                totalReads: 4
            ).first
        )

        XCTAssertEqual(summary.coverageBreadth, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.mappedReadPercent, 50.0, accuracy: 0.0001)
    }

    func testBuildSummariesDropsReferenceRowsWithNoMappedReads() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        allele-with-support\t1\t156\t4\t156\t100.0\t4.0\t30.0\t40.0
        allele-without-support\t1\t156\t0\t0\t0.0\t0.0\t0.0\t0.0
        """

        let viewOutput = """
        read1\t0\tallele-with-support\t1\t40\t156M\t*\t0\t0\tACGT\t*\tNM:i:0
        """

        let summaries = try MappingSummaryBuilder.buildSummaries(
            coverageOutput: coverageOutput,
            viewOutput: viewOutput,
            totalReads: 10,
            includeUnmappedReferenceRows: false
        )

        XCTAssertEqual(summaries.map(\.contigName), ["allele-with-support"])
    }

    func testBuildSummariesKeepsReferenceRowsWithNoMappedReadsByDefault() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        allele-with-support\t1\t156\t4\t156\t100.0\t4.0\t30.0\t40.0
        allele-without-support\t1\t156\t0\t0\t0.0\t0.0\t0.0\t0.0
        """

        let summaries = try MappingSummaryBuilder.buildSummaries(
            coverageOutput: coverageOutput,
            viewOutput: "",
            totalReads: 10
        )

        XCTAssertEqual(summaries.map(\.contigName), ["allele-with-support", "allele-without-support"])
        XCTAssertEqual(summaries[1].mappedReads, 0)
    }

    // MARK: - F36: concurrent stdout/stderr draining

    /// Regression test for F36: streamSAMView's underlying process runner used to read stdout
    /// to completion before reading stderr at all. macOS pipe buffers are ~64KB, so a child
    /// process that writes more than that to stderr before (or while) stdout is still being
    /// drained can block on a full stderr pipe while nothing is reading it -- deadlocking
    /// against this caller, which is itself blocked inside the stdout read. This stub writes
    /// >64KB to stderr FIRST, then writes to stdout, reproducing exactly that ordering.
    func testRunProcessCapturingOutputDoesNotDeadlockOnLargeStderrBeforeStdout() async throws {
        let scriptURL = try makeLargeStderrThenStdoutScript()
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // Race the (blocking, non-cancellable) process call against a short timeout. Pre-fix,
        // streamSAMView's sequential stdout-then-stderr read deadlocks on this stub (it writes
        // >64KB to stderr before any stdout), and the underlying synchronous pipe reads run on
        // a background thread that Task cancellation cannot interrupt -- so the only way to
        // observe the hang from a test without stalling the whole suite is to race it against
        // a short timeout and fail fast if the timeout wins.
        let outcome = await withTaskGroup(of: MappingSummaryTestOutcome.self) { group in
            group.addTask {
                do {
                    let stdout = try await MappingSummaryBuilder.runProcessCapturingOutput(
                        executableURL: scriptURL,
                        arguments: [],
                        workingDirectory: scriptURL.deletingLastPathComponent(),
                        timeout: 10
                    )
                    return .completed(.success(stdout))
                } catch {
                    return .completed(.failure(error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        guard case .completed(let result) = outcome else {
            XCTFail("process did not complete within the test timeout (deadlock reproduced)")
            return
        }
        let stdout = try result.get()
        XCTAssertTrue(stdout.contains("STDOUT_MARKER"), "expected stdout payload to be captured intact")
    }

    private func makeLargeStderrThenStdoutScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingSummaryBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("large_stderr_then_stdout.sh")

        // >64KB of stderr output (macOS pipe buffer is ~64KB) written before any stdout output.
        let script = """
        #!/bin/bash
        for i in $(seq 1 2000); do
            echo "stderr line $i: 0123456789012345678901234567890123456789" >&2
        done
        echo "STDOUT_MARKER"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

private enum MappingSummaryTestOutcome: Sendable {
    case completed(Result<String, Error>)
    case timedOut
}
