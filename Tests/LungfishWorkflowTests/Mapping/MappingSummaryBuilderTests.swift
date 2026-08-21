import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class MappingSummaryBuilderTests: XCTestCase {

    func testBuildUsesRealReadGroupPipeAndSampleSpecificDenominator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-rg-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("samtools.log")
        let samtools = bin.appendingPathComponent("samtools")
        try """
        #!/bin/bash
        echo "$*" >> "\(log.path)"
        if [[ "$1 $2" == "view -c" ]]; then echo 4; exit 0; fi
        if [[ "$1" == "view" ]]; then
          if [[ "$2" == "-R" ]]; then rg_list="$3"; elif [[ "$3" == "-R" ]]; then rg_list="$4"; else exit 91; fi
          grep -qx 'S1-A' "$rg_list" || exit 94
          grep -qx 'S1-B' "$rg_list" || exit 95
          printf '@HD\\tVN:1.6\\n'
          printf 'r1\\t0\\tchr1\\t1\\t60\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:0\\n'
          exit 0
        fi
        if [[ "$1" == "coverage" && "$2" == "-" ]]; then
          IFS= read -r header
          [[ "$header" == @HD* ]] || exit 92
          cat >/dev/null
          printf '#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'
          printf 'chr1\\t1\\t100\\t1\\t10\\t10.0\\t0.1\\t30\\t60\\n'
          exit 0
        fi
        exit 93
        """.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        let bam = root.appendingPathComponent("input.bam")
        try Data().write(to: bam)
        let summaries = try await MappingSummaryBuilder.build(
            sortedBAMURL: bam, totalReads: 99, readGroupIDs: ["S1-A", "S1-B"],
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root), timeout: 2
        )
        XCTAssertEqual(try XCTUnwrap(summaries.first).mappedReadPercent, 25, accuracy: 0.001)
        let invocationLog = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(invocationLog.contains("view -h -R"))
        XCTAssertTrue(invocationLog.contains("coverage -"))
        XCTAssertTrue(invocationLog.contains("view -c -R"))
    }

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

    // MARK: - R3-R3ML-first: cancellation wiring for samtools view

    /// Reproduces the missing-cancellation-wiring defect: runProcessCapturingOutput
    /// previously used a plain withCheckedThrowingContinuation with no
    /// withTaskCancellationHandler, so cancelling the enclosing Task never
    /// terminated the child samtools process -- the awaited call would keep
    /// blocking (and the orphaned process would keep running) until it
    /// finished or hit the timeout on its own. This stub sleeps far longer
    /// than the test should ever wait; if cancellation wiring works, the
    /// process is killed almost immediately.
    func testRunProcessCapturingOutputTerminatesProcessPromptlyWhenTaskIsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pidFile = root.appendingPathComponent("view.pid")
        let scriptURL = root.appendingPathComponent("fake_samtools_view.sh")
        try """
        #!/bin/bash
        /usr/bin/printf "%s" "$$" > "\(pidFile.path)"
        exec /bin/sleep 300
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let task = Task {
            try await MappingSummaryBuilder.runProcessCapturingOutput(
                executableURL: scriptURL,
                arguments: [],
                workingDirectory: root,
                timeout: 300
            )
        }

        // The stub's `printf > file` write is non-atomic: the file can exist
        // with partial (or as-yet-empty) contents before the PID is fully
        // flushed. Poll until the contents actually parse as a PID rather
        // than trusting a single read right after fileExists first succeeds
        // -- mirrors the terminationDeadline retry loop below.
        let deadline = Date().addingTimeInterval(30)
        var pid: Int32?
        while pid == nil, Date() < deadline {
            if FileManager.default.fileExists(atPath: pidFile.path),
               let pidString = try? String(contentsOf: pidFile, encoding: .utf8) {
                pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pid == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard let pid else {
            task.cancel()
            _ = try? await task.value
            XCTFail("stub samtools view process never wrote a valid PID file within the deadline")
            return
        }
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: pid), "stub samtools view process should have started")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate as an error")
        } catch is CancellationError {
            // expected
        } catch {
            // Some paths surface CancellationError wrapped differently; accept
            // any thrown error here since the real assertion is prompt process
            // termination below.
        }

        let terminationDeadline = Date().addingTimeInterval(5)
        var stillRunning = ProcessTreeTerminator.processExists(pid: pid)
        while stillRunning, Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            stillRunning = ProcessTreeTerminator.processExists(pid: pid)
        }
        XCTAssertFalse(stillRunning, "samtools view process (pid \(pid)) should be terminated promptly after Task cancellation")
    }

    func testCancellingReadGroupCoveragePipelineTerminatesViewAndCoverageProcessTrees() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-rg-pipeline-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bin = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let viewPIDFile = root.appendingPathComponent("view.pid")
        let viewChildPIDFile = root.appendingPathComponent("view-child.pid")
        let coveragePIDFile = root.appendingPathComponent("coverage.pid")
        let samtools = bin.appendingPathComponent("samtools")
        try """
        #!/bin/bash
        if [[ "$1" == "coverage" && "$2" == "-" ]]; then
          /usr/bin/printf "%s" "$$" > "\(coveragePIDFile.path)"
          /bin/cat >/dev/null
          exit 0
        fi
        if [[ "$1" == "view" && "$2" == "-h" ]]; then
          /usr/bin/printf "%s" "$$" > "\(viewPIDFile.path)"
          /bin/sleep 300 &
          /usr/bin/printf "%s" "$!" > "\(viewChildPIDFile.path)"
          wait
          exit 0
        fi
        if [[ "$1" == "view" && "$2" == "-c" ]]; then
          echo 1
          exit 0
        fi
        exit 91
        """.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        let bam = root.appendingPathComponent("input.bam")
        try Data().write(to: bam)

        let task = Task {
            try await MappingSummaryBuilder.build(
                sortedBAMURL: bam,
                totalReads: 1,
                readGroupIDs: ["S1-RG"],
                runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root),
                timeout: 300
            )
        }

        let startedPIDs = try await waitForPIDs(
            at: [viewPIDFile, viewChildPIDFile, coveragePIDFile],
            timeout: 10
        )
        XCTAssertEqual(startedPIDs.count, 3, "expected both pipeline roots and the view child to start")

        task.cancel()
        let terminationDeadline = Date().addingTimeInterval(5)
        while startedPIDs.contains(where: ProcessTreeTerminator.processExists), Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let livePIDs = startedPIDs.filter(ProcessTreeTerminator.processExists)
        XCTAssertTrue(livePIDs.isEmpty,
            "cancelling RG coverage must terminate both pipeline roots and the view child"
        )
        // Keep the RED path bounded: the pre-fix implementation ignores
        // cancellation, so explicitly clean up before awaiting its task.
        for pid in livePIDs {
            ProcessTreeTerminator.terminate(rootPID: pid, gracePeriod: 0)
        }

        do {
            _ = try await task.value
            XCTFail("Expected pipeline cancellation to throw")
        } catch is CancellationError {
            // expected
        } catch {
            if livePIDs.isEmpty {
                XCTFail("Expected CancellationError after pipeline termination, got \(error)")
            }
        }
    }

    // MARK: - Streaming SAM metrics

    func testBuildStreamsSummaryWhenSortedBAMExceedsFormerMemoryGuard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-oversized-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oversizedBAM = root.appendingPathComponent("oversized.bam")
        // Sparse-allocate a file just over the 2GB guard without writing 2GB of real bytes.
        FileManager.default.createFile(atPath: oversizedBAM.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedBAM)
        try handle.truncate(atOffset: UInt64(2_147_483_648) + 1)
        try handle.close()

        // The large compressed size is no longer a reason to omit identity/MAPQ
        // metrics: the SAM stream is parsed incrementally.
        let managedSamtoolsDir = root
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedSamtoolsDir, withIntermediateDirectories: true)
        let stubSamtools = managedSamtoolsDir.appendingPathComponent("samtools")
        try """
        #!/bin/bash
        if [[ "$1" == "coverage" ]]; then
          printf "#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n"
          printf "chr1\\t1\\t1000\\t3\\t800\\t80.0\\t6.5\\t30.0\\t43.3\\n"
          exit 0
        fi
        if [[ "$1" == "view" ]]; then
          printf 'read1\\t0\\tchr1\\t1\\t60\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:1\\n'
          exit 0
        fi
        exit 1
        """.write(to: stubSamtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubSamtools.path)

        let contigs = try await MappingSummaryBuilder.build(
            sortedBAMURL: oversizedBAM,
            totalReads: 10,
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root)
        )

        XCTAssertEqual(contigs.map(\.contigName), ["chr1"])
        XCTAssertEqual(contigs.first?.medianMAPQ, 60)
        XCTAssertEqual(try XCTUnwrap(contigs.first?.meanIdentity), 0.9, accuracy: 0.0001)
    }

    func testBuildStreamsLargeSAMOutputFromSmallBAM() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-large-sam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bam = root.appendingPathComponent("small-compressed.bam")
        try Data([0x1F, 0x8B]).write(to: bam)
        let bin = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let samtools = bin.appendingPathComponent("samtools")
        try """
        #!/bin/bash
        if [[ "$1" == "coverage" ]]; then
          printf '#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'
          printf 'chr1\\t1\\t100\\t200000\\t100\\t100.0\\t20000\\t30\\t40\\n'
          exit 0
        fi
        if [[ "$1" == "view" ]]; then
          /usr/bin/awk 'BEGIN { for (i = 1; i <= 200000; i++) print "read" i "\\t0\\tchr1\\t1\\t40\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:1" }'
          exit 0
        fi
        exit 1
        """.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)

        let summaries = try await MappingSummaryBuilder.build(
            sortedBAMURL: bam,
            totalReads: 200_000,
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root),
            timeout: 30
        )
        let summary = try XCTUnwrap(summaries.first)

        XCTAssertEqual(summary.medianMAPQ, 40)
        XCTAssertEqual(summary.meanIdentity, 0.9, accuracy: 0.0001)
    }

    // MARK: - F36: concurrent stdout/stderr draining

    /// Regression test for F36: the samtools-view process runner used to read stdout
    /// to completion before reading stderr at all. macOS pipe buffers are ~64KB, so a child
    /// process that writes more than that to stderr before (or while) stdout is still being
    /// drained can block on a full stderr pipe while nothing is reading it -- deadlocking
    /// against this caller, which is itself blocked inside the stdout read. This stub writes
    /// >64KB to stderr FIRST, then writes to stdout, reproducing exactly that ordering.
    func testRunProcessCapturingOutputDoesNotDeadlockOnLargeStderrBeforeStdout() async throws {
        let scriptURL = try makeLargeStderrThenStdoutScript()
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // Race the (blocking, non-cancellable) process call against a short timeout. Pre-fix,
        // A sequential stdout-then-stderr read deadlocks on this stub (it writes
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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    private func waitForPIDs(at urls: [URL], timeout: TimeInterval) async throws -> [Int32] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pids = urls.compactMap { url -> Int32? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pids.count == urls.count { return pids }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for pipeline PID files")
        return []
    }
}

private enum MappingSummaryTestOutcome: Sendable {
    case completed(Result<String, Error>)
    case timedOut
}

/// Lock-protected accumulator for warning strings reported from a `@Sendable` callback,
/// used instead of a captured `var` to satisfy strict concurrency checking.
