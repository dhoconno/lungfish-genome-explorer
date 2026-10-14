// OutputEquivalenceTests+Caller.swift - The launch caller a provenance envelope records is masked, a variant caller is not
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M3, ruling A53-M3 fix 1. A provenance envelope records `caller`, `gui` or `cli`,
// the entry point that launched the workflow. Once the app launches `lungfish-cli` for a route, the
// value is the route's identity, like the executable path, and the contract masks it
// (docs/contracts/CLI-EQUIVALENCE.md, Masks). The same key names the caller of a variant call in
// another record (`lofreq`, `ivar`), which is a fact of the run and stays compared. OutputEquivalenceTests
// is past the file-size baseline, so this test sits in an extension beside it.

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
        let envelope = { (caller: String) in
            #"{"options":{"resolvedDefaults":{"caller":""# + caller + #"","concurrency":2}}}"#
        }

        try Data(envelope("gui").utf8).write(to: a.appendingPathComponent("provenance.json"))
        try Data(envelope("cli").utf8).write(to: b.appendingPathComponent("provenance.json"))
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle), [], "gui and cli name the route, not the run")

        try Data(envelope("lofreq").utf8).write(to: a.appendingPathComponent("provenance.json"))
        try Data(envelope("ivar").utf8).write(to: b.appendingPathComponent("provenance.json"))
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, "a variant caller is a fact of the run")

        try Data(envelope("gui").utf8).write(to: a.appendingPathComponent("provenance.json"))
        try Data(envelope("lofreq").utf8).write(to: b.appendingPathComponent("provenance.json"))
        XCTAssertEqual(try OutputEquivalence.differences(a, b, kind: .bundle).count, 1, "a variant caller never reads as a launch caller")
    }
}
