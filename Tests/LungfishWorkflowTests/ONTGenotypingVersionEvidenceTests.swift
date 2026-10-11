// ONTGenotypingVersionEvidenceTests.swift - The pysam version of an ONT genotyping record is a lock pin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6, lane P4. Nothing runs pysam to ask its version, so the record names the lock's pin. That
// is a pin and not a measurement, and the evidence says so. The recorded string is the pinned version.

import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ONTGenotypingVersionEvidenceTests: XCTestCase {
    func testThePysamVersionIsTheLockPinForPysam() throws {
        let pinned = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ManagedToolID(rawValue: "pysam"))?.version)
        let evidence = ONTGenotypingPipeline.pysamVersionEvidence
        XCTAssertEqual(evidence, .lockPin(version: pinned, id: ManagedToolID(rawValue: "pysam")))
        XCTAssertEqual(evidence.recordedString, pinned)
        XCTAssertNotEqual(evidence, .observed(version: pinned, reportedLine: nil), "a pin is not a measurement")
    }

    func testThePysamIdIsALockToolsEntry() throws {
        let entry = try XCTUnwrap(ManagedToolLock.bundled.entry(id: ONTGenotypingPipeline.pysamID))
        XCTAssertEqual(entry.environment, "pysam")
        XCTAssertNotNil(ManagedToolLock.bundled.packageSpec(of: entry), "the record names the pinned package")
    }
}
