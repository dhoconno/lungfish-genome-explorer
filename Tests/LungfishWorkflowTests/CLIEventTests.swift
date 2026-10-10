import XCTest
@testable import LungfishWorkflow

/// Round-trip coverage for the shared `CLIEvent` wire schema.
/// Before this type existed, each `lungfish-cli` subcommand
/// declared a private per-command `Event` struct and the GUI parsed events
/// with `dict["message"] as? String`, so nothing checked that the two sides
/// agreed on field names. These tests are the contract check: every case
/// encodes and decodes to itself, and the decoder accepts the exact JSON
/// shapes the CLI emits today.
final class CLIEventTests: XCTestCase {
    private func roundTrip(_ event: CLIEvent) throws -> CLIEvent {
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        return try decoder.decode(CLIEvent.self, from: data)
    }

    func testStartRoundTrips() throws {
        let event = CLIEvent.start(message: "Starting tree inference.")
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testProgressRoundTripsAndClampsFraction() throws {
        let event = CLIEvent.progress(fraction: 0.5, message: "Running IQ-TREE.")
        XCTAssertEqual(try roundTrip(event), event)

        let overshoot = CLIEvent.progress(fraction: 1.5, message: "x")
        XCTAssertEqual(try roundTrip(overshoot), .progress(fraction: 1.0, message: "x"))

        let undershoot = CLIEvent.progress(fraction: -0.5, message: "x")
        XCTAssertEqual(try roundTrip(undershoot), .progress(fraction: 0.0, message: "x"))
    }

    func testLogRoundTrips() throws {
        let event = CLIEvent.log(level: .warning, message: "bare PATH detected")
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testOutputRoundTrips() throws {
        let event = CLIEvent.output(path: "/tmp/example.bam", role: "alignment")
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testCompleteRoundTripsWithMultipleOutputs() throws {
        let event = CLIEvent.complete(outputs: ["/a", "/b"], message: "done")
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testFailedRoundTripsWithDetail() throws {
        let event = CLIEvent.failed(message: "node not found: ABC", detail: "stderr excerpt")
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testFailedRoundTripsWithoutDetail() throws {
        let event = CLIEvent.failed(message: "node not found: ABC", detail: nil)
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testDecoderAcceptsSingularOutputFieldForComplete() throws {
        let json = #"{"event":"complete","output":"/project/x.lungfishtree","progress":1}"#
        let decoder = CLIEventLineDecoder()
        let event = try decoder.decode(line: json)
        XCTAssertEqual(event, .complete(outputs: ["/project/x.lungfishtree"], message: nil))
    }

    func testDecoderReturnsNilForNonEventLines() throws {
        let decoder = CLIEventLineDecoder()
        XCTAssertNil(try decoder.decode(line: "Wrote tree bundle: /path"))
        XCTAssertNil(try decoder.decode(line: ""))
    }

    /// A name this reader does not know is an ignored line, not an error, so a newer
    /// writer can add an event without every running app logging a failure per line.
    func testDecoderIgnoresAnUnknownEventNameInsteadOfThrowing() throws {
        let decoder = CLIEventLineDecoder()
        XCTAssertNil(try decoder.decode(line: #"{"event":"somethingElse"}"#))

        let line = try XCTUnwrap(decoder.decodeLine(#"{"event":"somethingElse","schemaVersion":3}"#))
        XCTAssertNil(line.event)
        XCTAssertEqual(line.eventName, "somethingElse")
        XCTAssertEqual(line.schemaVersion, 3)
        XCTAssertTrue(line.artifacts.isEmpty)

        let nameless = try XCTUnwrap(decoder.decodeLine(#"{"progress":0.5}"#))
        XCTAssertNil(nameless.event)
        XCTAssertNil(nameless.eventName)
    }

    /// What still throws is a line that is broken at a version this reader knows.
    func testDecoderThrowsForBrokenLinesAtAKnownVersion() {
        let decoder = CLIEventLineDecoder()
        XCTAssertThrowsError(try decoder.decode(line: #"{"event":"progress""#), "truncated JSON")
        XCTAssertThrowsError(try decoder.decode(line: #"{"event":"progress","progress":"half"}"#), "a wrong type")
        XCTAssertThrowsError(
            try decoder.decode(line: #"{"schemaVersion":2,"event":"progress","progress":"half"}"#), "a wrong type at version 2")
        XCTAssertNoThrow(
            try decoder.decode(line: #"{"schemaVersion":3,"event":"progress","progress":"half"}"#), "the same at version 3")
    }

    func testEveryEncodedEventCarriesTheCurrentSchemaVersion() throws {
        let events: [CLIEvent] = [
            .start(message: "s"),
            .progress(fraction: 0.5, message: "p"),
            .log(level: .warning, message: "l"),
            .output(path: "/a", role: "r"),
            .complete(outputs: ["/a"], message: nil),
            .failed(message: "f", detail: nil),
        ]
        for event in events {
            let object = try jsonObject(try JSONEncoder().encode(event))
            XCTAssertEqual(object["schemaVersion"] as? Int, CLIEventLine.currentSchemaVersion, "\(event)")
            XCTAssertEqual(object["event"] as? String, event.wireName, "\(event)")
        }
        XCTAssertEqual(CLIEventLine.currentSchemaVersion, 2)
    }

    /// Older apps read these keys, so the version 2 line keeps every one of them.
    func testVersion2LinesKeepTheKeysVersion1ReadersUse() throws {
        let start = try jsonObject(try JSONEncoder().encode(CLIEvent.start(message: "go")))
        XCTAssertEqual(start["progress"] as? Double, 0)
        XCTAssertEqual(start["message"] as? String, "go")

        let complete = try jsonObject(try JSONEncoder().encode(CLIEvent.complete(outputs: ["/b", "/a"], message: "done")))
        XCTAssertEqual(complete["outputs"] as? [String], ["/b", "/a"])
        XCTAssertEqual(complete["output"] as? String, "/b")
        XCTAssertEqual(complete["progress"] as? Double, 1)
        XCTAssertEqual(complete["message"] as? String, "done")
        XCTAssertNil(complete["artifacts"])

        let failed = try jsonObject(try JSONEncoder().encode(CLIEvent.failed(message: "bad", detail: "why")))
        XCTAssertEqual(failed["error"] as? String, "bad")
        XCTAssertEqual(failed["detail"] as? String, "why")
    }

    func testAnEventAndItsEnvelopeWithoutArtifactsWriteTheSameBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let event = CLIEvent.complete(outputs: ["/a", "/b"], message: "done")
        XCTAssertEqual(try encoder.encode(event), try encoder.encode(CLIEventLine(event: event)))
    }

    func testEnvelopeRoundTripsWithArtifacts() throws {
        let artifacts = [
            CLIEventArtifact(kind: "lungfishtree", path: "/work/t.lungfishtree", role: "tree", provenancePath: "/work/t.lungfishtree/.lungfish-provenance.json"),
            CLIEventArtifact(kind: "", path: "/work/log.txt"),
        ]
        let complete = CLIEventLine(event: .complete(outputs: ["/work/t.lungfishtree"], message: nil), artifacts: artifacts)
        XCTAssertEqual(try roundTripLine(complete), complete)

        let output = CLIEventLine(event: .output(path: "/work/a.bam", role: "alignment"), artifacts: [artifacts[0]])
        XCTAssertEqual(try roundTripLine(output), output)
    }

    func testArtifactsRideOnlyOnCompleteAndOutputLines() throws {
        let artifact = CLIEventArtifact(kind: "k", path: "/a")
        let events: [CLIEvent] = [
            .start(message: "s"), .progress(fraction: 0.1, message: "p"), .log(level: .info, message: "l"),
            .failed(message: "f", detail: nil),
        ]
        for event in events {
            let line = CLIEventLine(event: event, artifacts: [artifact])
            XCTAssertTrue(line.artifacts.isEmpty, "\(event)")
            let object = try jsonObject(try JSONEncoder().encode(line))
            XCTAssertNil(object["artifacts"], "\(event)")
        }
        for event in [CLIEvent.complete(outputs: ["/a"], message: nil), .output(path: "/a", role: "r")] {
            XCTAssertEqual(CLIEventLine(event: event, artifacts: [artifact]).artifacts, [artifact], "\(event)")
        }
    }

    func testAnIgnoredLineCannotBeWrittenAgain() throws {
        let line = try XCTUnwrap(CLIEventLineDecoder().decodeLine(#"{"event":"somethingElse"}"#))
        XCTAssertThrowsError(try JSONEncoder().encode(line))
    }

    func testEmitterLinesCarryTheVersionAndTheArtifactsOfAComplete() throws {
        var lines: [String] = []
        let emitter = CLIEventEmitter(enabled: true) { lines.append($0) }
        let artifact = CLIEventArtifact(
            kind: "alignment", path: "/work/a.bam", role: "primary", provenancePath: "/work/a.provenance.json")
        emitter.emitStart("Begin.")
        emitter.emitProgress(0.5, message: "Half.")
        emitter.emitLog(.warning, "Careful.")
        emitter.emitOutput(path: "/work/a.bam", role: "alignment")
        emitter.emitComplete(outputs: ["/work/a.bam", "/work/a.bam.bai"], artifacts: [artifact], message: "Done.")
        emitter.emitFailed("Broken.", detail: "why")

        XCTAssertEqual(lines.count, 6)
        for line in lines {
            XCTAssertFalse(line.contains(Character("\n")), line)
            XCTAssertEqual(try jsonObject(Data(line.utf8))["schemaVersion"] as? Int, 2, line)
        }
        let decoder = CLIEventLineDecoder()
        let complete = try XCTUnwrap(decoder.decodeLine(lines[4]))
        XCTAssertEqual(complete.event, .complete(outputs: ["/work/a.bam", "/work/a.bam.bai"], message: "Done."))
        XCTAssertEqual(complete.artifacts, [artifact])
        XCTAssertEqual(complete.schemaVersion, 2)
        for index in [0, 1, 2, 5] {
            XCTAssertTrue(try XCTUnwrap(decoder.decodeLine(lines[index])).artifacts.isEmpty)
        }
    }

    func testDisabledEmitterWritesNoArtifactLine() {
        var lines: [String] = []
        let emitter = CLIEventEmitter(enabled: false) { lines.append($0) }
        emitter.emitComplete(outputs: ["/a"], artifacts: [CLIEventArtifact(kind: "k", path: "/a")])
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: Helpers

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roundTripLine(_ line: CLIEventLine) throws -> CLIEventLine {
        try JSONDecoder().decode(CLIEventLine.self, from: JSONEncoder().encode(line))
    }

    func testEmitterWritesOneLinePerEventWhenEnabled() {
        var lines: [String] = []
        let emitter = CLIEventEmitter(enabled: true) { lines.append($0) }
        emitter.emitStart("Starting.")
        emitter.emitProgress(0.5, message: "Halfway.")
        emitter.emitComplete(output: "/out")
        XCTAssertEqual(lines.count, 3)

        let decoder = CLIEventLineDecoder()
        XCTAssertEqual(try decoder.decode(line: lines[0]), .start(message: "Starting."))
        XCTAssertEqual(try decoder.decode(line: lines[1]), .progress(fraction: 0.5, message: "Halfway."))
        XCTAssertEqual(try decoder.decode(line: lines[2]), .complete(outputs: ["/out"], message: nil))
    }

    func testEmitterIsNoOpWhenDisabled() {
        var lines: [String] = []
        let emitter = CLIEventEmitter(enabled: false) { lines.append($0) }
        emitter.emitStart("Starting.")
        emitter.emitFailed("boom")
        XCTAssertTrue(lines.isEmpty)
    }
}
