// ClassifierAlignmentEvidenceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class ClassifierAlignmentEvidenceTests: XCTestCase {
    func testEvidenceRequestRetainsFinalEvidenceIdentityAndValidationInputs() throws {
        let bamURL = URL(fileURLWithPath: "/results/final/reads.bam")
        let indexURL = URL(fileURLWithPath: "/results/final/reads.bam.csi")
        let referenceURL = URL(fileURLWithPath: "/results/final/reference.fasta")

        let request = try ClassifierAlignmentEvidenceRequest(
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

    func testEvidenceRequestRejectsWhitespaceRequiredIdentityFields() {
        XCTAssertThrowsError(try makeRequest(stableID: " ")) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .emptyStableResultID
            )
        }
        XCTAssertThrowsError(try makeRequest(provenanceID: "\n")) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .emptyProvenanceID
            )
        }
        XCTAssertThrowsError(try makeRequest(sampleID: "\t")) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .emptyCanonicalSampleID
            )
        }
    }

    func testEvidenceRequestRejectsInvalidContigAndReferenceShapes() {
        XCTAssertThrowsError(try makeRequest(contigName: " ")) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .emptyContigName
            )
        }
        XCTAssertThrowsError(try makeRequest(contigLength: 0)) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .invalidContigLength(0)
            )
        }
        XCTAssertThrowsError(try makeRequest(referenceLength: -1)) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .invalidReferenceLength(-1)
            )
        }
    }

    func testEvidenceRequestRejectsEmptyPresentationLabelsAndInconsistentIndexExtension() {
        XCTAssertThrowsError(try makeRequest(workflowLabel: " ")) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .emptyPresentationLabel("workflowLabel")
            )
        }
        XCTAssertThrowsError(try makeRequest(indexURL: URL(fileURLWithPath: "/results/final/reads.bam.bai"))) { error in
            XCTAssertEqual(
                error as? ClassifierAlignmentEvidenceRequest.ValidationError,
                .indexExtensionDoesNotMatchKind(expected: "csi", actual: "bai")
            )
        }
    }

    func testWorkflowKindsAreLimitedToMigratedClassifierWorkflows() {
        XCTAssertEqual(
            Set(ClassifierAlignmentWorkflowKind.allCases),
            Set([.esViritu, .taxTriage, .nvd])
        )
    }

    private func makeRequest(
        stableID: String = "run-42",
        provenanceID: String = "provenance-42",
        indexURL: URL = URL(fileURLWithPath: "/results/final/reads.bam.csi"),
        sampleID: String = "sample-A",
        contigName: String = "NC_000001.11",
        contigLength: Int = 248_956_422,
        referenceLength: Int = 248_956_422,
        workflowLabel: String = "TaxTriage"
    ) throws -> ClassifierAlignmentEvidenceRequest {
        try ClassifierAlignmentEvidenceRequest(
            workflow: .taxTriage,
            resultIdentity: .init(
                stableID: stableID,
                finalResultURL: URL(fileURLWithPath: "/results/final/run-42.lungfish"),
                provenanceID: provenanceID
            ),
            bamURL: URL(fileURLWithPath: "/results/final/reads.bam"),
            index: .init(url: indexURL, kind: .csi),
            sample: .init(canonicalID: sampleID),
            contig: .init(name: contigName, expectedLength: contigLength),
            referenceCandidate: .init(
                fastaURL: URL(fileURLWithPath: "/results/final/reference.fasta"),
                recordName: "NC_000001.11",
                expectedLength: referenceLength
            ),
            presentation: .init(
                workflowLabel: workflowLabel,
                resultLabel: "Run 42",
                sampleLabel: "Sample A",
                contigLabel: "chr1"
            )
        )
    }
}
