// UnsignedWriterFamiliesSigningTests+VCFImport.swift - S4, injectable defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10). `VCFBundleVariantImport.publish` takes its provenance writer as an argument that defaults
// to the writer of the family. `attachInProcess` passes no writer, so the record it publishes comes from that default.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension UnsignedWriterFamiliesSigningTests {
    /// With a key set, the record that an in-process VCF attach publishes beside the new track is signed at the name it
    /// keeps, because the call passes no writer and takes the default.
    func testVCFAttachWithNoWriterArgumentPublishesASignedRecord() throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let bundleURL = try makeVariantBundle()
        let vcfURL = root.appendingPathComponent("calls.vcf")
        try Self.variantVCFText.write(to: vcfURL, atomically: true, encoding: .utf8)

        let result = try VCFBundleVariantImport.attachInProcess(
            VCFBundleVariantImport.Request(vcfURL: vcfURL, bundleURL: bundleURL)
        ) { _ in
            let step = StepExecution(
                toolName: "fixture", toolVersion: "1", command: ["fixture"], inputs: [], outputs: [], exitCode: 0
            )
            let run = WorkflowRun(
                name: "VCF attach fixture", endTime: Date(), status: .completed, steps: [step], parameters: [:]
            )
            return run.canonicalEnvelope()
        }

        XCTAssertEqual(result.variantCount, 2)
        try assertSignedOnce(result.provenanceURL, "a VCF attached with no writer argument")
    }
}
