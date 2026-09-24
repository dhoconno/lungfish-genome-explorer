import XCTest
@testable import LungfishWorkflow

/// Round-trip coverage for the shared `CLIEvent` wire schema (ARC-02,
/// SIMP-04). Before this type existed, each `lungfish-cli` subcommand
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

    func testDecoderThrowsForUnknownEventName() throws {
        let decoder = CLIEventLineDecoder()
        XCTAssertThrowsError(try decoder.decode(line: #"{"event":"somethingElse"}"#))
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
