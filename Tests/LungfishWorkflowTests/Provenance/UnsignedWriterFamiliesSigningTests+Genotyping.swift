// UnsignedWriterFamiliesSigningTests+Genotyping.swift - S7, genotyping records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10). The full-length genotyping flow writes its record once and later rewrites it with the
// executed publication receipt, copying the first write's signature references into the new envelope. A keyless
// rewrite keeps the old pair and its reference while the bytes change, so the record would fail to verify. Both writes
// of the flow sign together, and the rewrite replaces the pair, so the record names one signature and verifies.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension UnsignedWriterFamiliesSigningTests {
    /// The first write signs. The receipt rewrite at the end of the publication reads that record back and writes it
    /// again, and the record at its final path still verifies and names exactly one signature.
    func testFullLengthPublicationReceiptRewriteKeepsTheRecordSigned() throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let provenanceURL = root.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
        let step = StepExecution(
            toolName: "fixture", toolVersion: "1", command: ["fixture"], inputs: [], outputs: [], exitCode: 0
        )
        let run = WorkflowRun(
            name: "Full-length MHC fixture", endTime: Date(), status: .completed, steps: [step], parameters: [:]
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(), toSidecar: provenanceURL)
        try assertSignedOnce(provenanceURL, "the first write of a full-length genotyping record")

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = FullLengthONTMHCResultBundlePublicationRecord(
            stagedDirectoryURL: root.appendingPathComponent("staged", isDirectory: true),
            finalDirectoryURL: root.appendingPathComponent("final", isDirectory: true),
            payloadMappings: [],
            replacingExisting: false,
            publicationMechanism: "renameatx_np",
            successManifestMechanism: "renameatx_np",
            fallbackReason: nil,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            exitStatus: 0,
            errorMessage: nil
        )
        try FullLengthONTMHCGenotypingPipeline().writeExecutedPublicationReceipt(
            record, provenanceURL: provenanceURL, replacingPriorReceipt: false
        )

        let rewritten = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertTrue(
            rewritten.steps.contains { $0.toolName == "lungfish-internal publish-result-bundle" },
            "the rewrite did not add the publication step"
        )
        try assertSignedOnce(provenanceURL, "a full-length genotyping record after the receipt rewrite")
    }
}
