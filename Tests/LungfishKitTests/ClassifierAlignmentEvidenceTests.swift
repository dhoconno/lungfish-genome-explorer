// ClassifierAlignmentEvidenceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class ClassifierAlignmentEvidenceTests: XCTestCase {
    func testEvidenceRequestRetainsFinalEvidenceIdentityAndValidationInputs() {
        let bamURL = URL(fileURLWithPath: "/results/final/reads.bam")
        let indexURL = URL(fileURLWithPath: "/results/final/reads.bam.csi")
        let referenceURL = URL(fileURLWithPath: "/results/final/reference.fasta")

        let request = ClassifierAlignmentEvidenceRequest(
            workflow: .taxTriage,
            resultIdentity: .init(
                stableID: "run-42",
                finalResultURL: URL(fileURLWithPath: "/results/final/run-42.lungfish"),
                provenanceID: "provenance-42"
            ),
            bamURL: bamURL,
            index: .init(url: indexURL, kind: .csi),
            sample: .init(canonicalID: "sample-A"),
            contig: .init(name: "NC_000001.11", expectedLength: 248_956_422),
            referenceCandidate: .init(
                fastaURL: referenceURL,
                recordName: "NC_000001.11",
                expectedLength: 248_956_422,
                expectedMD5: "1b22b98cdeb4a9304cb5d48026a85128"
            ),
            presentation: .init(
                workflowLabel: "TaxTriage",
                resultLabel: "Run 42",
                sampleLabel: "Sample A",
                contigLabel: "chr1"
            )
        )

        XCTAssertEqual(request.workflow, .taxTriage)
        XCTAssertEqual(request.resultIdentity.stableID, "run-42")
        XCTAssertEqual(request.bamURL, bamURL)
        XCTAssertEqual(request.index, .init(url: indexURL, kind: .csi))
        XCTAssertEqual(request.sample.canonicalID, "sample-A")
        XCTAssertEqual(request.contig.expectedLength, 248_956_422)
        XCTAssertEqual(request.referenceCandidate?.expectedMD5, "1b22b98cdeb4a9304cb5d48026a85128")
        XCTAssertEqual(request.presentation.contigLabel, "chr1")
    }

    func testWorkflowKindsAreLimitedToMigratedClassifierWorkflows() {
        XCTAssertEqual(
            Set(ClassifierAlignmentWorkflowKind.allCases),
            Set([.esViritu, .taxTriage, .nvd])
        )
    }
}
