import XCTest
@testable import LungfishApp
import LungfishKit

final class CLITreeTransformRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testParseStartEvent() throws {
        let json = #"{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .start(progress, message) = event else {
            return XCTFail("Expected start event, got \(event)")
        }
        XCTAssertEqual(progress, 0)
        XCTAssertEqual(message, "Starting tree transform.")
    }

    func testParseProgressEvent() throws {
        let json = #"{"event":"treeTransformProgress","progress":0.65,"message":"Writing transformed tree bundle."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .progress(progress, message) = event else {
            return XCTFail("Expected progress event, got \(event)")
        }
        XCTAssertEqual(progress, 0.65, accuracy: 0.0001)
        XCTAssertEqual(message, "Writing transformed tree bundle.")
    }

    func testParseCompleteEvent() throws {
        let json = #"{"event":"treeTransformComplete","progress":1,"output":"/project/Phylogenetic Trees/example-rerooted.lungfishtree"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .complete(output) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(output, "/project/Phylogenetic Trees/example-rerooted.lungfishtree")
    }

    func testParseFailedEvent() throws {
        let json = #"{"event":"treeTransformFailed","error":"node not found: ABC"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .failed(error) = event else {
            return XCTFail("Expected failed event, got \(event)")
        }
        XCTAssertEqual(error, "node not found: ABC")
    }

    func testParseIgnoresNonJSONAndUnknownEvents() throws {
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: "Wrote tree bundle: /path"))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: ""))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: #"{"event":"somethingElse"}"#))
    }
}
