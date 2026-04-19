// AssemblyCompatibilityTests.swift - Tests for the v1 assembly compatibility matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class AssemblyCompatibilityTests: XCTestCase {
    func testIlluminaShortReadsEnableOnlySPAdesMEGAHITAndSKESA() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .illuminaShortReads)),
            [.spades, .megahit, .skesa]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .spades, for: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .flye, for: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .illuminaShortReads))
    }

    func testONTReadsEnableOnlyFlye() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .ontReads)),
            [.flye]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .flye, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .ontReads))
    }

    func testPacBioHiFiEnablesOnlyHifiasm() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .pacBioHiFi)),
            [.hifiasm]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .flye, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, for: .pacBioHiFi))
    }

    func testMixedDetectedReadTypesAreBlockedInV1() {
        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: [.illuminaShortReads, .ontReads])

        XCTAssertTrue(evaluation.isBlocked)
        XCTAssertEqual(evaluation.blockingMessage, AssemblyCompatibility.hybridAssemblyUnsupportedMessage)
        XCTAssertEqual(
            evaluation.blockingMessage,
            "Hybrid assembly is not supported in v1. Select one read class per run."
        )
        XCTAssertEqual(evaluation.supportedTools, [])
    }
}
