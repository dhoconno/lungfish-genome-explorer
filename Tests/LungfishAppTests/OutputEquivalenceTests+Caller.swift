// OutputEquivalenceTests+Caller.swift - The launch caller a provenance envelope records is masked, a variant caller is not
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M3, ruling A53-M3 fix 1 and 2. A provenance envelope records `caller`, `gui` or `cli`,
// the entry point that launched the workflow. Once the app launches `lungfish-cli` for a route, the
// value is the route's identity, like the executable path, and the contract masks it
// (docs/contracts/CLI-EQUIVALENCE.md, Masks). The same key names the caller of a variant call in
// another record (`lofreq`, `ivar`), which is a fact of the run and stays compared. An envelope writes an
// option as a `ParameterValue`, an object with a `type` and a `value`, so the test writes both that shape,
// which the real records hold, and a bare string. OutputEquivalenceTests is past the file-size baseline,
// so this test sits in an extension beside it.

import Foundation
import XCTest
import LungfishTestSupport

extension OutputEquivalenceTests {
    func testProvenanceMasksALaunchCallerButNotAVariantCaller() throws {
        let scratch = try TestTempDirectory.make(prefix: "output-equivalence-caller")
        defer { TestTempDirectory.cleanup(scratch) }
        let a = scratch.appendingPathComponent("A", isDirectory: true)
        let b = scratch.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        func envelope(_ caller: String, wrapped: Bool) throws -> Data {
            let value: Any = wrapped ? ["type": "string", "value": caller] : caller
            let object: [String: Any] = ["options": ["resolvedDefaults": ["caller": value, "concurrency": 2]]]
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }

        for wrapped in [true, false] {
            let shape = wrapped ? "ParameterValue" : "bare string"
            try envelope("gui", wrapped: wrapped).write(to: a.appendingPathComponent("provenance.json"))
            try envelope("cli", wrapped: wrapped).write(to: b.appendingPathComponent("provenance.json"))
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [], "gui and cli name the route, not the run (\(shape))")

            try envelope("lofreq", wrapped: wrapped).write(to: a.appendingPathComponent("provenance.json"))
            try envelope("ivar", wrapped: wrapped).write(to: b.appendingPathComponent("provenance.json"))
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, "a variant caller is a fact of the run (\(shape))")

            try envelope("gui", wrapped: wrapped).write(to: a.appendingPathComponent("provenance.json"))
            try envelope("lofreq", wrapped: wrapped).write(to: b.appendingPathComponent("provenance.json"))
            XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, "a variant caller never reads as a launch caller (\(shape))")
        }
    }
}
