// MSAActionCLIEventEmitterTests.swift - The MSA action complete event carries its warning count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishWorkflow

final class MSAActionCLIEventEmitterTests: XCTestCase {
    func testCompleteEventCarriesWarningCountAndStillDecodes() throws {
        var lines: [String] = []
        let emitter = MSAActionCLIEventEmitter(enabled: true, emit: { lines.append($0) })
        emitter.emitComplete(actionID: "msa.distance", output: "/tmp/out.tsv", warningCount: 2)

        let line = try XCTUnwrap(lines.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["warningCount"] as? Int, 2)
        XCTAssertEqual(object["event"] as? String, "complete")
        XCTAssertEqual(object["outputs"] as? [String], ["/tmp/out.tsv"])

        let decoded = try JSONDecoder().decode(CLIEvent.self, from: Data(line.utf8))
        XCTAssertEqual(decoded, .complete(outputs: ["/tmp/out.tsv"], message: nil))
    }

    func testDisabledEmitterWritesNothing() {
        var lines: [String] = []
        let emitter = MSAActionCLIEventEmitter(enabled: false, emit: { lines.append($0) })
        emitter.emitComplete(actionID: "msa.distance", output: "/tmp/out.tsv", warningCount: 1)
        XCTAssertTrue(lines.isEmpty)
    }
}
