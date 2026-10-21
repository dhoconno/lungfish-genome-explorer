// AssemblyThreadCapNoteTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// UX word W2 under the assembly dialog's Threads row (Phase 2.13 lane 13.19 M2). The note shows for MEGAHIT on a
// host that caps it, and its number is the constant the command builder reads.

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyThreadCapNoteTests: XCTestCase {
    private let appleSilicon = AssemblyExecutionHost(operatingSystem: .macOS, architecture: "arm64")
    private let intelMac = AssemblyExecutionHost(operatingSystem: .macOS, architecture: "x86_64")
    private let otherSystem = AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")

    func testMegahitOnAppleSiliconShowsWordW2WithTheCap() {
        XCTAssertEqual(
            AssemblyThreadCapNote.text(tool: .megahit, host: appleSilicon),
            "On Apple silicon MEGAHIT runs on at most 1 thread, because more threads can crash it."
        )
    }

    func testNoNoteForAnotherToolOrAnotherHost() {
        XCTAssertNil(AssemblyThreadCapNote.text(tool: .spades, host: appleSilicon))
        XCTAssertNil(AssemblyThreadCapNote.text(tool: .skesa, host: appleSilicon))
        XCTAssertNil(AssemblyThreadCapNote.text(tool: .megahit, host: intelMac))
        XCTAssertNil(AssemblyThreadCapNote.text(tool: .megahit, host: otherSystem))
    }

    func testTheNoteNamesTheCountTheRequestIsHeldTo() throws {
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [],
            projectName: "cap-note",
            outputDirectory: URL(fileURLWithPath: "/tmp/cap-note"),
            threads: 16
        )
        let held = request.effectiveThreadCount(on: appleSilicon)
        XCTAssertEqual(held, AssemblyExecutionHost.megahitThreadCap)
        let text = try XCTUnwrap(AssemblyThreadCapNote.text(tool: .megahit, host: appleSilicon))
        XCTAssertTrue(text.contains("at most \(held) thread"), text)
    }
}
