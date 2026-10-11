// FASTQIngestionVersionEvidenceTests.swift - Where a FASTQ ingestion step's tool version comes from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6, lane P4. A step used to record a version from the lock when the probe failed, and
// nothing in the record said so. The version is now typed evidence, observed when a probe answered
// and a lock pin when it did not. The recorded string is the same either way.

import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class FASTQIngestionVersionEvidenceTests: XCTestCase {
    /// A probe that answers is observed, and the version is the one it printed.
    func testAnAnsweringProbeIsObserved() {
        let evidence = FASTQIngestionPipeline.versionEvidence(observed: "40.02", for: .clumpify)
        XCTAssertEqual(evidence, .observed(version: "40.02", reportedLine: nil))
        XCTAssertEqual(evidence.recordedString, "40.02")
    }

    /// A probe that does not answer leaves the lock's pin for the tool's own id, never a measurement.
    /// Every wrapper of BBTools shares `bbtools`, and bgzip and pigz have their own entries.
    func testAMissingProbeIsTheLockPinOfTheToolsId() {
        let cases: [(NativeTool, String)] = [
            (.clumpify, "bbtools"), (.reformat, "bbtools"), (.trimGalore, "trim_galore"),
            (.bgzip, "htslib"), (.pigz, "pigz"),
        ]
        for (tool, id) in cases {
            let evidence = FASTQIngestionPipeline.versionEvidence(observed: nil, for: tool)
            guard case .lockPin(let version, let toolID) = evidence else {
                XCTFail("\(tool) is not a lock pin: \(evidence)")
                continue
            }
            XCTAssertEqual(toolID.rawValue, id, "\(tool)")
            XCTAssertEqual(version, ManagedToolLock.bundled.entry(id: toolID)?.version, "\(tool)")
            XCTAssertEqual(evidence.recordedString, version, "\(tool) records the pinned version")
            XCTAssertNotEqual(evidence, .observed(version: version, reportedLine: nil), "\(tool) is a pin, not observed")
        }
    }

    /// With no probe and no pin there is no version, and the record keeps the word it always kept.
    func testNoProbeAndNoPinIsUnknown() {
        let emptyLock = ManagedToolLock(
            packID: "empty", displayName: "Empty", version: "0", tools: [], managedData: []
        )
        let evidence = FASTQIngestionPipeline.versionEvidence(observed: nil, for: .bgzip, lock: emptyLock)
        XCTAssertEqual(evidence, .unknown(.noProbe))
        XCTAssertEqual(evidence.recordedString, "unknown")
        XCTAssertNil(evidence.version)
    }
}
