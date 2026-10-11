import XCTest
import Foundation
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

final class CLIPrimerTrimRunnerTests: XCTestCase {
    func testRunCompletesForFastExitingCLIProcess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPrimerTrimRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cliURL = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"start","message":"starting","progress":0}'
        printf '%s\\n' '{"event":"complete","output":"/tmp/trimmed.bam","outputs":["/tmp/trimmed.bam","/tmp/trimmed.bam.bai","/tmp/trimmed.primer-trim-provenance.json"],"message":"trackID=trimmed trackName=Trimmed"}'
        exit 0
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cliURL.path
        )

        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cliURL.path, 1)
        defer {
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        final class Capturer: @unchecked Sendable {
            var events: [CLIEvent] = []
        }
        let capturer = Capturer()

        let runner = CLIPrimerTrimRunner()
        let result = try await runner.run(arguments: ["bam", "primer-trim"]) { event in
            capturer.events.append(event)
        }

        XCTAssertTrue(capturer.events.contains { event in
            if case .start = event { return true }
            return false
        })
        XCTAssertEqual(result.trackID, "trimmed")
        XCTAssertEqual(result.trackName, "Trimmed")
        XCTAssertEqual(result.bamPath, "/tmp/trimmed.bam")
        XCTAssertEqual(result.baiPath, "/tmp/trimmed.bam.bai")
        XCTAssertEqual(result.provenanceSidecarPath, "/tmp/trimmed.primer-trim-provenance.json")
    }

    func testCancelTerminatesCLIProcessTree() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPrimerTrimRunnerCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let childPIDURL = tempDir.appendingPathComponent("child.pid")
        let cliURL = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        nohup /bin/sh -c 'trap "" TERM HUP INT; while :; do sleep 1; done' >/dev/null 2>&1 &
        echo "$!" > "\(childPIDURL.path)"
        printf '%s\\n' '{"event":"start","message":"starting","progress":0}'
        while kill -0 "$!" 2>/dev/null; do
          sleep 0.1
        done
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cliURL.path
        )

        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cliURL.path, 1)
        defer {
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let runner = CLIPrimerTrimRunner()
        let runTask = Task {
            try await runner.run(arguments: ["bam", "primer-trim"]) { _ in }
        }
        let childPID = try await waitForPIDFile(childPIDURL)
        defer { ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0) }

        await runner.cancel()
        _ = await runTask.result

        try await waitForProcessExit(pid: childPID)
    }

    /// The runner finds the trimmed BAM, its index and its record by their place in
    /// `outputs`, so a writer keeps that order whatever order it lists artifacts in.
    func testOutputsAreReadInTheirVersion1OrderWhateverTheArtifactOrder() async throws {
        let folder = try TestTempDirectory.make(prefix: "primer-trim-order")
        defer { TestTempDirectory.cleanup(folder) }
        let bam = "/work/Sample.lungfishref/alignments/primer-trimmed/aln_1.bam"
        let bai = bam + ".bai"
        let record = "/work/Sample.lungfishref/alignments/primer-trimmed/aln_1.primer-trim-provenance.json"
        let complete = """
        {"artifacts":[{"kind":"provenance","path":"\(record)","role":"provenance"},\
        {"kind":"bai","path":"\(bai)","role":"alignment-index"},\
        {"kind":"bam","path":"\(bam)","provenancePath":"\(record)","role":"alignment"}],\
        "event":"complete","message":"trackID=aln_1 trackName=Sample 1 • Primer Trim","output":"\(bam)",\
        "outputs":["\(bam)","\(bai)","\(record)"],"progress":1,"schemaVersion":2}
        """
        let cli = try standInCLI(in: folder, printing: [
            #"{"event":"start","message":"Starting primer trim","progress":0,"schemaVersion":2}"#,
            complete,
        ])

        let result = try await CLIPrimerTrimRunner(cliURLOverride: cli).run(arguments: ["bam", "primer-trim"])

        XCTAssertEqual(result, CLIPrimerTrimResult(
            trackID: "aln_1",
            trackName: "Sample 1 • Primer Trim",
            bamPath: bam,
            baiPath: bai,
            provenanceSidecarPath: record
        ))
    }

    /// The runner gives its caller paths and never hands an output to bundle import. The
    /// trimmed BAM is already inside the reference bundle, which the caller reloads, so
    /// nothing reaches `onBundleReadyWithContext`, from a version 1 or a version 2 CLI.
    @MainActor
    func testTheRunnerHandsNoOutputToBundleImport() async throws {
        let folder = try TestTempDirectory.make(prefix: "primer-trim-import")
        defer { TestTempDirectory.cleanup(folder) }
        let version1 = try standInCLI(in: folder, printing: [
            #"{"event":"start","message":"starting","progress":0}"#,
            #"{"event":"complete","output":"/tmp/trimmed.bam","outputs":["/tmp/trimmed.bam","/tmp/trimmed.bam.bai","/tmp/trimmed.primer-trim-provenance.json"],"message":"trackID=trimmed trackName=Trimmed"}"#,
        ])
        let imports = ImportedBundleCapture()
        let saved = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { urls, _ in imports.append(urls) }
        defer { OperationCenter.shared.onBundleReadyWithContext = saved }

        let result = try await CLIPrimerTrimRunner(cliURLOverride: version1).run(arguments: ["bam", "primer-trim"])
        let version2Folder = try TestTempDirectory.make(prefix: "primer-trim-import-v2")
        defer { TestTempDirectory.cleanup(version2Folder) }
        let version2 = try standInCLI(in: version2Folder, printing: try Self.version2Transcript())
        let typedResult = try await CLIPrimerTrimRunner(cliURLOverride: version2).run(arguments: ["bam", "primer-trim"])

        XCTAssertEqual(result.bamPath, "/tmp/trimmed.bam")
        XCTAssertEqual(typedResult.bamPath, Self.capturedBAM)
        XCTAssertEqual(imports.calls, [], "nothing of a primer trim run reaches bundle import")
    }

    // MARK: - The version 2 exemplar (Phase 2.6 lane C3)

    /// The trimmed BAM of the captured version 2 run, inside the reference bundle at
    /// `alignments/primer-trimmed/<track id>.bam`, where it lands today.
    private static let capturedBAM = "/work/Sample.lungfishref/alignments/primer-trimmed/aln_DA825F94.bam"
    private static let capturedRecord = "/work/Sample.lungfishref/alignments/primer-trimmed/aln_DA825F94.primer-trim-provenance.json"

    /// `Tests/Fixtures/cli-events/v2/bam-primer-trim.ndjson`, a version 2 run of
    /// `bam primer-trim` captured in process on the sarscov2 fixture.
    private static func version2Transcript() throws -> [String] {
        let url = CLIEventCompatCorpus.v1Folder
            .deletingLastPathComponent()
            .appendingPathComponent("v2/bam-primer-trim.ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// A version 2 CLI types the trimmed BAM, its index and its record, and the runner
    /// reads them by role. The same completion with its artifacts taken away, as a
    /// version 1 CLI writes it, gives the same result from the places in `outputs`.
    func testAVersion2RunIsReadFromItsTypedArtifactsAndMatchesVersion1() async throws {
        let lines = try Self.version2Transcript()
        let complete = try XCTUnwrap(lines.last)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(complete.utf8)) as? [String: Any])
        XCTAssertNotNil(object["artifacts"], "the captured completion is typed")
        object.removeValue(forKey: "artifacts")
        object.removeValue(forKey: "schemaVersion")
        let untyped = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)

        let typedFolder = try TestTempDirectory.make(prefix: "primer-trim-v2")
        defer { TestTempDirectory.cleanup(typedFolder) }
        let untypedFolder = try TestTempDirectory.make(prefix: "primer-trim-v1")
        defer { TestTempDirectory.cleanup(untypedFolder) }
        let typed = try await CLIPrimerTrimRunner(cliURLOverride: try standInCLI(in: typedFolder, printing: lines))
            .run(arguments: ["bam", "primer-trim"])
        let positional = try await CLIPrimerTrimRunner(
            cliURLOverride: try standInCLI(in: untypedFolder, printing: Array(lines.dropLast()) + [untyped])
        ).run(arguments: ["bam", "primer-trim"])

        XCTAssertEqual(typed, CLIPrimerTrimResult(
            trackID: "aln_DA825F94",
            trackName: "Primer-trimmed Sample",
            bamPath: Self.capturedBAM,
            baiPath: Self.capturedBAM + ".bai",
            provenanceSidecarPath: Self.capturedRecord
        ))
        XCTAssertEqual(positional, typed)
    }

    /// The frozen version 1 reader reads the version 2 transcript to the same events,
    /// so an older app gets the same outcome and `outputs`, in their version 1 order.
    func testTheFrozenVersion1ReaderReadsTheVersion2TranscriptToTheSameOutcome() throws {
        let frozen = FrozenCLIEventV1LineDecoder()
        let current = CLIEventLineDecoder()
        let lines = try Self.version2Transcript()

        let frozenEvents = try lines.map { try XCTUnwrap(try frozen.decode(line: $0), $0) }
        let currentLines = try lines.map { try XCTUnwrap(try current.decodeLine($0), $0) }

        XCTAssertEqual(currentLines.compactMap(\.event).count, lines.count, "every line holds an event this reader knows")
        XCTAssertEqual(frozenEvents.map(\.asCLIEvent), currentLines.compactMap(\.event))
        XCTAssertEqual(currentLines.map(\.schemaVersion), Array(repeating: 2, count: lines.count))
        XCTAssertEqual(frozenEvents.filter(\.isTerminal).count, 1)
        XCTAssertEqual(frozenEvents.last, .complete(
            outputs: [Self.capturedBAM, Self.capturedBAM + ".bai", Self.capturedRecord],
            message: "trackID=aln_DA825F94 trackName=Primer-trimmed Sample"
        ))
        XCTAssertEqual(currentLines.last?.artifacts.map(\.role), [
            CLIEventArtifact.Role.alignment,
            CLIEventArtifact.Role.alignmentIndex,
            CLIEventArtifact.Role.provenance,
        ])
    }

    /// Typed artifacts are read first. Each role a CLI did not type falls back to its
    /// place in `outputs`.
    func testTypedArtifactsAreReadFirstAndAMissingRoleFallsBackToItsPlace() async throws {
        let folder = try TestTempDirectory.make(prefix: "primer-trim-roles")
        defer { TestTempDirectory.cleanup(folder) }
        let complete = """
        {"artifacts":[{"kind":"bam","path":"/typed/trimmed.bam","role":"alignment"},\
        {"kind":"provenance","path":"/typed/trimmed.primer-trim-provenance.json","role":"provenance"}],\
        "event":"complete","message":"trackID=aln_2 trackName=Typed",\
        "outputs":["/listed/trimmed.bam","/listed/trimmed.bam.bai","/listed/trimmed.primer-trim-provenance.json"],\
        "schemaVersion":2}
        """
        let cli = try standInCLI(in: folder, printing: [complete])

        let result = try await CLIPrimerTrimRunner(cliURLOverride: cli).run(arguments: ["bam", "primer-trim"])

        XCTAssertEqual(result.bamPath, "/typed/trimmed.bam")
        XCTAssertEqual(result.baiPath, "/listed/trimmed.bam.bai", "an untyped index falls back to its place")
        XCTAssertEqual(result.provenanceSidecarPath, "/typed/trimmed.primer-trim-provenance.json")
    }

    func testBuildCLIArgumentsIncludesAllRequiredFlags() {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/proj/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample"
        )

        XCTAssertEqual(arguments[0], "bam")
        XCTAssertEqual(arguments[1], "primer-trim")
        XCTAssertTrue(arguments.contains("--bundle"))
        XCTAssertTrue(arguments.contains("/tmp/proj/Sample.lungfishref"))
        XCTAssertTrue(arguments.contains("--alignment-track"))
        XCTAssertTrue(arguments.contains("aln-1"))
        XCTAssertTrue(arguments.contains("--scheme"))
        XCTAssertTrue(arguments.contains("/tmp/QIASeq.lungfishprimers"))
        XCTAssertTrue(arguments.contains("--name"))
        XCTAssertTrue(arguments.contains("Primer-trimmed Sample"))
        XCTAssertTrue(arguments.contains("--format"))
        XCTAssertTrue(arguments.contains("json"))
    }
}

/// A shell script in place of `lungfish-cli` that prints `lines` on standard output.
private func standInCLI(in folder: URL, printing lines: [String]) throws -> URL {
    let transcript = folder.appendingPathComponent("events.ndjson")
    try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    let url = folder.appendingPathComponent("lungfish-cli")
    try "#!/bin/sh\n/bin/cat '\(transcript.path)'\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// What reached `onBundleReadyWithContext`, one array of paths per call.
private final class ImportedBundleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    var calls: [[String]] { lock.withLock { stored } }
    func append(_ urls: [URL]) { lock.withLock { stored.append(urls.map(\.path)) } }
}

/// Waits until the script has written the child's PID. The shell creates the
/// file before it writes the number, so an empty or partial read means "not
/// yet". The 30 s timeouts leave room for the parallel unit tier, and both
/// waits return as soon as their condition holds.
private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 30) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(url.path)")
    throw CancellationError()
}

private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ProcessTreeTerminator.processExists(pid: pid) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Process \(pid) was still running after cancellation")
}
