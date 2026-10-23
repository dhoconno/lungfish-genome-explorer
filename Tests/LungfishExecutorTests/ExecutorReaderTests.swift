import Dispatch
import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private typealias Support = ExecutorTestSupport

/// The portable reader through ``ExecutorChildLauncher``: the pigz route against the Mac's `gzip -dc` route (tally K3.2),
/// the pigz child in the cancel path (K3.1) and the launcher's pipe contract (`RUNNING-A-TOOL.md`, the review's C3 rows).
final class ExecutorReaderTests: XCTestCase {
    private func gzipRoute() -> ExecutorChildLauncher {
        ExecutorChildLauncher(controller: StepController())
    }

    private func pigzRoute(_ pigz: String, log: ReaderChildLog = ReaderChildLog()) -> ExecutorChildLauncher {
        ExecutorChildLauncher(controller: StepController(), decompressor: pigz, log: log)
    }

    private func counts(_ url: URL, _ launcher: ExecutorChildLauncher, _ fixtures: ReaderFixtures, _ name: String) throws -> ReadCommand.Counts {
        try ReadCommand.inspect(url, launcher: launcher, streamOut: "\(fixtures.folder)/\(name).stream")
    }

    /// The file and reason of the `unreadableInput` that `body` throws, or nil.
    private func unreadable(_ body: () throws -> Any) -> (file: String, reason: String)? {
        do {
            _ = try body()
            XCTFail("the read succeeded")
        } catch FASTQPairInterleaver.InterleaveError.unreadableInput(let file, let reason) {
            return (file, reason)
        } catch {
            XCTFail("expected unreadableInput, got \(error)")
        }
        return nil
    }

    /// A stand-in decompressor that answers `--version` and otherwise runs `body`.
    private func fakeDecompressor(in folder: String, _ body: String) throws -> String {
        let path = "\(folder)/fake-pigz"
        let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'fake-pigz 0.0'; exit 0; fi\n\(body)\n"
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o755), 0)
        return path
    }

    /// A file that starts with the gzip magic, so the reader starts its decompressor.
    private func gzipLookingFile(in folder: String) throws -> URL {
        let url = URL(fileURLWithPath: "\(folder)/input.fastq.gz")
        try (Data([0x1F, 0x8B, 0x08, 0x00]) + Data(repeating: 0, count: 16)).write(to: url)
        return url
    }

    private func pidFileBody(_ folder: String, _ name: String) -> String {
        "echo $$ > \"\(folder)/\(name).tmp\"; mv \"\(folder)/\(name).tmp\" \"\(folder)/\(name).pid\""
    }

    private func readReport(_ folder: String) throws -> ReadCommand.Report {
        try JSONDecoder().decode(ReadCommand.Report.self, from: Data(contentsOf: URL(fileURLWithPath: "\(folder)/read.out")))
    }

    // MARK: - K3.2, the decompression tests

    func testPigzReaderMatchesGzipOnConcatenatedBGZF() throws {
        let pigz = try ReaderTools.pigz()
        let fixtures = try ReaderFixtures.make(pigz: nil)
        let bgzf = try Data(contentsOf: fixtures.bgzf)
        let starts = ReaderFixtures.blockStarts(bgzf)
        XCTAssertEqual(starts.last, bgzf.count, "every block parses as BGZF")
        XCTAssertGreaterThanOrEqual(starts.count - 2, 3, "at least three data blocks before the EOF block")
        XCTAssertEqual(Array(bgzf.suffix(28)), ReaderFixtures.bgzfEOF)
        let log = ReaderChildLog()
        let throughPigz = try counts(fixtures.bgzf, pigzRoute(pigz, log: log), fixtures, "pigz")
        let throughGzip = try counts(fixtures.bgzf, gzipRoute(), fixtures, "gzip")
        XCTAssertEqual(throughPigz, throughGzip)
        XCTAssertEqual(throughPigz, try counts(fixtures.plain, gzipRoute(), fixtures, "plain"))
        XCTAssertEqual(throughPigz.records, ReaderFixtures.recordCount)
        XCTAssertEqual(log.all.count, 2)
        for end in log.all {
            XCTAssertEqual(end.executable, pigz)
            XCTAssertEqual(end.arguments, ["-dc", fixtures.bgzf.path])
            XCTAssertTrue(end.isSuccess)
        }
    }

    func testTruncatedGzipFailsRead() throws {
        let pigz = try ReaderTools.pigz()
        let fixtures = try ReaderFixtures.make(pigz: nil)
        let failure = unreadable { try FASTQPairInterleaver.countRecords(in: fixtures.cutShort, launcher: pigzRoute(pigz)) }
        XCTAssertEqual(failure?.file, "cut.fastq.gz")
        XCTAssertEqual(failure?.reason, "gzip decompression failed (exit 1)")
    }

    func testPortableAndMacDecompressionGiveEqualStreamsAndFailures() throws {
        let pigz = try ReaderTools.pigz()
        let fixtures = try ReaderFixtures.make(pigz: pigz)
        let plain = try counts(fixtures.plain, gzipRoute(), fixtures, "plain")
        XCTAssertGreaterThan(plain.q20Bases, plain.q30Bases)
        XCTAssertGreaterThan(plain.q30Bases, 0)
        for url in [fixtures.bgzf, fixtures.pigzMade, fixtures.single] {
            let name = url.lastPathComponent
            let portable = try counts(url, pigzRoute(pigz), fixtures, "portable-\(name)")
            let mac = try counts(url, gzipRoute(), fixtures, "mac-\(name)")
            XCTAssertEqual(portable, mac, name)
            XCTAssertEqual(portable, plain, name)
        }
        // F-A2: the two routes fail with the same exit, while their partial output and stderr differ.
        for url in [fixtures.cutShort, fixtures.badCRC] {
            let portable = unreadable { try ReadCommand.inspect(url, launcher: pigzRoute(pigz)) }
            let mac = unreadable { try ReadCommand.inspect(url, launcher: gzipRoute()) }
            XCTAssertEqual(portable?.file, url.lastPathComponent)
            XCTAssertEqual(mac?.file, url.lastPathComponent)
            XCTAssertEqual(portable?.reason, mac?.reason, url.lastPathComponent)
        }
    }

    func testTruncatedGzipFailsWithSameReasonThroughBothLaunchers() throws {
        let pigz = try ReaderTools.pigz()
        let fixtures = try ReaderFixtures.make(pigz: nil)
        let linux = unreadable { try FASTQPairInterleaver.countRecords(in: fixtures.cutShort, launcher: pigzRoute(pigz)) }
        let gzip = unreadable { try FASTQPairInterleaver.countRecords(in: fixtures.cutShort, launcher: gzipRoute()) }
        // `GzipReaderSitePinTests` pins these words for `ToolProcessChildLauncher`, which this target cannot import.
        XCTAssertEqual(linux?.reason, "gzip decompression failed (exit 1)")
        XCTAssertEqual(gzip?.reason, linux?.reason)
    }

    func testMultiMemberBGZFReadsEveryRecordThroughLinuxLauncher() throws {
        let pigz = try ReaderTools.pigz()
        let fixtures = try ReaderFixtures.make(pigz: nil)
        let records = try FASTQPairInterleaver.countRecords(in: fixtures.bgzf, launcher: pigzRoute(pigz))
        XCTAssertEqual(records, try FASTQPairInterleaver.countRecords(in: fixtures.plain, launcher: gzipRoute()))
        XCTAssertEqual(records, ReaderFixtures.recordCount)

        // The same read through the binary, whose report names the decompressor and its version line.
        let pid = try Support.spawn(
            try Support.executorBinary(),
            ["read-fastq", "--decompressor", pigz, "--stream-out", "\(fixtures.folder)/binary.stream", fixtures.bgzf.path],
            folder: fixtures.folder, name: "read"
        )
        let exit = Support.waitForExit(pid, timeout: 60)
        XCTAssertEqual(exit?.termination, .exited(code: ExecutorExitCode.succeeded))
        let report = try readReport(fixtures.folder)
        XCTAssertEqual(report.outcome, "succeeded")
        XCTAssertEqual(report.records, ReaderFixtures.recordCount)
        XCTAssertEqual(report.decompressor, pigz)
        XCTAssertTrue(report.decompressorVersion?.hasPrefix("pigz ") ?? false, "\(report.decompressorVersion ?? "none")")
        XCTAssertEqual(report.streamSHA256, try PortableDigest.sha256Hex(ofFileAt: fixtures.plain))
    }

    // MARK: - K3.1, the pigz child in the cancel path

    func testReaderChildStopsWithTheToolsTreeOnInterrupt() throws {
        let folder = try Support.scratchFolder()
        let fake = try fakeDecompressor(in: folder, "\(pidFileBody(folder, "r")); exec sleep 60")
        let controller = StepController()
        let reader = try FASTQRawLineReader(
            url: try gzipLookingFile(in: folder),
            launcher: ExecutorChildLauncher(controller: controller, decompressor: fake, graceSeconds: 2)
        )
        let readerPID = try Support.pid(in: folder, "r.pid")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { controller.interrupt(SIGTERM) }
        let started = Date()
        let result = controller.run(StepSpec(
            executable: "/bin/sleep", arguments: ["60"], environment: [:], stdoutPath: "\(folder)/tool.out",
            stderrPath: "\(folder)/tool.err", outputs: [], graceSeconds: 2, deadlineSeconds: nil, sweepIntervalSeconds: 0.05
        ))
        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertThrowsError(try reader.nextLine())
        XCTAssertTrue(Support.isGone(readerPID))
    }

    func testSIGTERMToExecutorStopsTheReadersDecompressor() throws {
        let folder = try Support.scratchFolder()
        let fake = try fakeDecompressor(in: folder, "\(pidFileBody(folder, "r")); exec sleep 60")
        let executor = try Support.spawn(
            try Support.executorBinary(),
            ["read-fastq", "--decompressor", fake, "--grace", "3", try gzipLookingFile(in: folder).path],
            folder: folder, name: "read"
        )
        let readerPID = try Support.pid(in: folder, "r.pid")
        XCTAssertEqual(Support.parent(of: readerPID), executor)
        let started = Date()
        XCTAssertEqual(kill(executor, SIGTERM), 0)
        let exit = Support.waitForExit(executor, timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the grace is 3 s")
        XCTAssertEqual(exit?.termination, .exited(code: ExecutorExitCode.interrupted))
        let report = try readReport(folder)
        XCTAssertEqual(report.outcome, "interrupted")
        XCTAssertEqual(report.signal, SIGTERM)
        XCTAssertEqual(report.decompressorVersion, "fake-pigz 0.0")
        XCTAssertTrue(report.children.contains { $0.pid == readerPID && $0.stopped && !$0.isSuccess }, "\(report.children)")
        XCTAssertTrue(Support.isGone(readerPID))
    }

    // MARK: - The launcher's pipe contract (RUNNING-A-TOOL.md)

    func testChildWritingPastThePipeBufferDoesNotBlock() throws {
        let started = Date()
        let child = try gzipRoute().start(PortableChildRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"],
            environment: ["PATH": "/usr/bin:/bin"], label: "writer"
        ))
        var total = 0
        while true {
            let piece = child.readStdout(filling: 262_144)
            total += piece.count
            if piece.count < 262_144 { break }
        }
        XCTAssertEqual(try child.waitForExit(), PortableChildExit(status: 0, isSuccess: true))
        XCTAssertEqual(total, 1_048_576)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testDescendantHoldingStdoutIsStoppedAfterDrainGrace() throws {
        let folder = try Support.scratchFolder()
        let binary = try Support.executorBinary()
        let holder = "\(pidFileBody(folder, "g")); exec sleep 60"
        #if os(Linux)
        // A new session, so only the executor's adoption of orphans finds it (the subreaper).
        let start = "\"\(binary)\" setsid-exec /bin/sh -c '\(holder)' &"
        #else
        // macOS has no subreaper, so the holder stays in the decompressor's group, where the group stop reaches it.
        let start = "/bin/sh -c '\(holder)' &"
        #endif
        let fake = try fakeDecompressor(in: folder, "\(start)\nwhile [ ! -s \"\(folder)/g.pid\" ]; do sleep 0.1; done\nexit 0")
        let started = Date()
        let executor = try Support.spawn(
            binary, ["read-fastq", "--decompressor", fake, "--grace", "3", try gzipLookingFile(in: folder).path],
            folder: folder, name: "read"
        )
        let exit = Support.waitForExit(executor, timeout: 40)
        let elapsed = Date().timeIntervalSince(started)
        let holderPID = try Support.pid(in: folder, "g.pid", timeout: 1)
        XCTAssertEqual(exit?.termination, .exited(code: ExecutorExitCode.failed))
        XCTAssertGreaterThanOrEqual(elapsed, ExecutorChildLauncher.defaultDrainGraceSeconds)
        XCTAssertLessThan(elapsed, 25)
        let report = try readReport(folder)
        XCTAssertEqual(report.outcome, "failed")
        XCTAssertEqual(report.reason, StepReason.lingeringProcess)
        XCTAssertTrue(report.children.contains { $0.drainExpired && !$0.isSuccess && $0.exitCode == 0 }, "\(report.children)")
        XCTAssertTrue(Support.isGone(holderPID))
    }

    func testExitMinusOneReads255() throws {
        XCTAssertEqual(ExecutorSpawn.decode(status: 0xFF00), .exited(code: 255))
        let (exit, record) = try Support.runStep(folder: try Support.scratchFolder(), ["/bin/sh", "-c", "exit 255"])
        XCTAssertEqual(record.toolExitCode, 255)
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.failed))
    }

    func testReaderGoneEndsWriteWithoutSIGPIPE() throws {
        ExecutorSignals.ignoreBrokenPipe()
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0)
        close(ends[0])
        let written = [UInt8](repeating: 0x41, count: 1).withUnsafeBytes { write(ends[1], $0.baseAddress, 1) }
        let saved = errno
        close(ends[1])
        XCTAssertEqual(written, -1)
        XCTAssertEqual(saved, EPIPE)
        #if os(Linux)
        // The child's dispositions are its own. None of the six defaulted signals is ignored in it.
        let child = try gzipRoute().start(PortableChildRequest(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: ["/proc/self/status"], environment: [:], label: "status"
        ))
        let status = String(decoding: child.readStdout(filling: 1 << 20), as: UTF8.self)
        XCTAssertTrue(try child.waitForExit().isSuccess)
        let line = status.split(separator: "\n").first { $0.hasPrefix("SigIgn:") }
        let mask = try XCTUnwrap(line.flatMap { UInt64($0.dropFirst("SigIgn:".count).trimmingCharacters(in: .whitespaces), radix: 16) })
        for signal in ExecutorSpawn.defaultedSignals {
            XCTAssertEqual(mask & (UInt64(1) << UInt64(signal - 1)), 0, "signal \(signal) is ignored in the child")
        }
        #endif
    }
}
