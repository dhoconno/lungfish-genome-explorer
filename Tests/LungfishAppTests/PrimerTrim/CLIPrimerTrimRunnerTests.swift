import XCTest
import Foundation
import LungfishIO
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
        printf '%s\\n' '{"event":"runStart","message":"starting"}'
        printf '%s\\n' '{"event":"runComplete","outputAlignmentTrackID":"trimmed","outputAlignmentTrackName":"Trimmed","bamPath":"/tmp/trimmed.bam","baiPath":"/tmp/trimmed.bam.bai","provenanceSidecarPath":"/tmp/trimmed.primer-trim-provenance.json"}'
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
            var events: [CLIPrimerTrimEvent] = []
        }
        let capturer = Capturer()

        let runner = CLIPrimerTrimRunner()
        try await runner.run(arguments: ["bam", "primer-trim"]) { event in
            capturer.events.append(event)
        }

        XCTAssertTrue(capturer.events.contains { event in
            if case .runStart = event { return true }
            return false
        })
        XCTAssertTrue(capturer.events.contains { event in
            if case .runComplete(let trackID, let trackName, _, _, _) = event {
                return trackID == "trimmed" && trackName == "Trimmed"
            }
            return false
        })
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

    func testParseEventDecodesRunStart() throws {
        let line = #"{"event":"runStart","message":"Starting primer trim"}"#
        let event = try XCTUnwrap(CLIPrimerTrimRunner.parseEvent(from: line))
        guard case .runStart(let message) = event else {
            XCTFail("Expected .runStart, got \(event)")
            return
        }
        XCTAssertEqual(message, "Starting primer trim")
    }

    func testParseEventDecodesStageProgress() throws {
        let line = #"{"event":"stageProgress","progress":0.45,"message":"trim 45%"}"#
        let event = try XCTUnwrap(CLIPrimerTrimRunner.parseEvent(from: line))
        guard case .stageProgress(let progress, let message) = event else {
            XCTFail("Expected .stageProgress, got \(event)")
            return
        }
        XCTAssertEqual(progress, 0.45, accuracy: 0.0001)
        XCTAssertEqual(message, "trim 45%")
    }

    func testParseEventDecodesRunComplete() throws {
        let line = #"""
        {"event":"runComplete","progress":1.0,"message":"Primer trim complete","bundlePath":"/tmp/p.lungfishref","sourceAlignmentTrackID":"aln-source","outputAlignmentTrackID":"aln-trimmed","outputAlignmentTrackName":"Trimmed","bamPath":"/tmp/p.lungfishref/alignments/primer-trimmed/x.bam","baiPath":"/tmp/p.lungfishref/alignments/primer-trimmed/x.bam.bai","provenanceSidecarPath":"/tmp/p.lungfishref/alignments/primer-trimmed/x.primer-trim-provenance.json"}
        """#
        let event = try XCTUnwrap(CLIPrimerTrimRunner.parseEvent(from: line))
        guard case .runComplete(let trackID, let trackName, let bamPath, _, _) = event else {
            XCTFail("Expected .runComplete, got \(event)")
            return
        }
        XCTAssertEqual(trackID, "aln-trimmed")
        XCTAssertEqual(trackName, "Trimmed")
        XCTAssertTrue(bamPath.hasSuffix("x.bam"))
    }

    func testParseEventReturnsNilForNonJSONLine() throws {
        XCTAssertNil(try CLIPrimerTrimRunner.parseEvent(from: "Starting primer trim"))
        XCTAssertNil(try CLIPrimerTrimRunner.parseEvent(from: ""))
    }

    func testParseEventReturnsNilForUnknownEvent() throws {
        let line = #"{"event":"madeUpEvent","message":"x"}"#
        XCTAssertNil(try CLIPrimerTrimRunner.parseEvent(from: line))
    }
}
