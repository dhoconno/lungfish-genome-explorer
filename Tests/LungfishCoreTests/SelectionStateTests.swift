// SelectionStateTests.swift - Unit tests for SelectionState enum
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SelectionStateTests: XCTestCase {

    // MARK: - None Case Tests

    func testNoneCaseEquality() {
        let state1 = SelectionState.none
        let state2 = SelectionState.none

        XCTAssertEqual(state1, state2)
    }

    func testNoneHasNoSelection() {
        let state = SelectionState.none

        XCTAssertFalse(state.hasSelection)
    }

    func testNoneIsNotRegionSelection() {
        let state = SelectionState.none

        XCTAssertFalse(state.isRegionSelection)
    }

    func testNoneIsNotAnnotationSelection() {
        let state = SelectionState.none

        XCTAssertFalse(state.isAnnotationSelection)
    }

    func testNoneSelectedAnnotationIsNil() {
        let state = SelectionState.none

        XCTAssertNil(state.selectedAnnotation)
    }

    func testNoneSelectedRegionIsNil() {
        let state = SelectionState.none

        XCTAssertNil(state.selectedRegion)
    }

    func testNoneSelectionLengthIsNil() {
        let state = SelectionState.none

        XCTAssertNil(state.selectionLength)
    }

    func testNoneDescription() {
        let state = SelectionState.none

        XCTAssertEqual(state.description, "No selection")
    }

    // MARK: - Region Case Tests

    func testRegionCaseEqualityWithSameValues() {
        let state1 = SelectionState.region(chromosome: "chr1", start: 100, end: 200)
        let state2 = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertEqual(state1, state2)
    }

    func testRegionCaseInequalityWithDifferentChromosome() {
        let state1 = SelectionState.region(chromosome: "chr1", start: 100, end: 200)
        let state2 = SelectionState.region(chromosome: "chr2", start: 100, end: 200)

        XCTAssertNotEqual(state1, state2)
    }

    func testRegionCaseInequalityWithDifferentStart() {
        let state1 = SelectionState.region(chromosome: "chr1", start: 100, end: 200)
        let state2 = SelectionState.region(chromosome: "chr1", start: 150, end: 200)

        XCTAssertNotEqual(state1, state2)
    }

    func testRegionCaseInequalityWithDifferentEnd() {
        let state1 = SelectionState.region(chromosome: "chr1", start: 100, end: 200)
        let state2 = SelectionState.region(chromosome: "chr1", start: 100, end: 250)

        XCTAssertNotEqual(state1, state2)
    }

    func testRegionHasSelection() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertTrue(state.hasSelection)
    }

    func testRegionIsRegionSelection() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertTrue(state.isRegionSelection)
    }

    func testRegionIsNotAnnotationSelection() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertFalse(state.isAnnotationSelection)
    }

    func testRegionSelectedAnnotationIsNil() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertNil(state.selectedAnnotation)
    }

    func testRegionSelectedRegionReturnsCorrectValue() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        let region = state.selectedRegion
        XCTAssertNotNil(region)
        XCTAssertEqual(region?.chromosome, "chr1")
        XCTAssertEqual(region?.start, 100)
        XCTAssertEqual(region?.end, 200)
    }

    func testRegionSelectionLength() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertEqual(state.selectionLength, 100)
    }

    func testRegionSelectionLengthZero() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 100)

        XCTAssertEqual(state.selectionLength, 0)
    }

    func testRegionSelectionLengthLarge() {
        let state = SelectionState.region(chromosome: "chr1", start: 0, end: 1_000_000)

        XCTAssertEqual(state.selectionLength, 1_000_000)
    }

    func testRegionDescription() {
        let state = SelectionState.region(chromosome: "chr1", start: 100, end: 200)

        XCTAssertEqual(state.description, "Region: chr1:100-200")
    }

    func testRegionDescriptionWithLargeCoordinates() {
        let state = SelectionState.region(chromosome: "chrX", start: 12345678, end: 23456789)

        XCTAssertEqual(state.description, "Region: chrX:12345678-23456789")
    }

    // MARK: - Annotation Case Tests

    func testAnnotationCaseEqualityBySameID() {
        let annotationID = UUID()
        let annotation1 = SequenceAnnotation(
            id: annotationID,
            type: .gene,
            name: "BRCA1",
            start: 0,
            end: 100
        )
        let annotation2 = SequenceAnnotation(
            id: annotationID,
            type: .cds,  // Different type, same ID
            name: "Different",
            start: 200,
            end: 300
        )

        let state1 = SelectionState.annotation(annotation1)
        let state2 = SelectionState.annotation(annotation2)

        // Equality is based on annotation ID only
        XCTAssertEqual(state1, state2)
    }

    func testAnnotationCaseInequalityWithDifferentID() {
        let annotation1 = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 0,
            end: 100
        )
        let annotation2 = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",  // Same name but different UUID
            start: 0,
            end: 100
        )

        let state1 = SelectionState.annotation(annotation1)
        let state2 = SelectionState.annotation(annotation2)

        // Different UUIDs mean different selections
        XCTAssertNotEqual(state1, state2)
    }

    func testAnnotationHasSelection() {
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertTrue(state.hasSelection)
    }

    func testAnnotationIsNotRegionSelection() {
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertFalse(state.isRegionSelection)
    }

    func testAnnotationIsAnnotationSelection() {
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertTrue(state.isAnnotationSelection)
    }

    func testAnnotationSelectedAnnotationReturnsCorrectValue() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 2000
        )
        let state = SelectionState.annotation(annotation)

        let selected = state.selectedAnnotation
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.id, annotation.id)
        XCTAssertEqual(selected?.name, "BRCA1")
        XCTAssertEqual(selected?.type, .gene)
        XCTAssertEqual(selected?.start, 1000)
        XCTAssertEqual(selected?.end, 2000)
    }

    func testAnnotationSelectedRegionIsNil() {
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        // Annotations don't store chromosome context, so selectedRegion is nil
        XCTAssertNil(state.selectedRegion)
    }

    func testAnnotationSelectionLengthSingleInterval() {
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertEqual(state.selectionLength, 100)
    }

    func testAnnotationSelectionLengthMultipleIntervals() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "SplicedGene",
            intervals: [
                AnnotationInterval(start: 0, end: 100),     // 100 bp
                AnnotationInterval(start: 200, end: 300),  // 100 bp
                AnnotationInterval(start: 500, end: 700)   // 200 bp
            ]
        )
        let state = SelectionState.annotation(annotation)

        // Total length is sum of all intervals
        XCTAssertEqual(state.selectionLength, 400)
    }

    func testAnnotationDescription() {
        let annotation = SequenceAnnotation(type: .gene, name: "BRCA1", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertEqual(state.description, "Annotation: BRCA1 (gene)")
    }

    func testAnnotationDescriptionWithCDSType() {
        let annotation = SequenceAnnotation(type: .cds, name: "CDS_001", start: 0, end: 100)
        let state = SelectionState.annotation(annotation)

        XCTAssertEqual(state.description, "Annotation: CDS_001 (CDS)")
    }

    // MARK: - Cross-Case Equality Tests

    func testNoneNotEqualToRegion() {
        let none = SelectionState.none
        let region = SelectionState.region(chromosome: "chr1", start: 0, end: 100)

        XCTAssertNotEqual(none, region)
    }

    func testNoneNotEqualToAnnotation() {
        let none = SelectionState.none
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let annotationState = SelectionState.annotation(annotation)

        XCTAssertNotEqual(none, annotationState)
    }

    func testRegionNotEqualToAnnotation() {
        let region = SelectionState.region(chromosome: "chr1", start: 0, end: 100)
        let annotation = SequenceAnnotation(type: .gene, name: "Test", start: 0, end: 100)
        let annotationState = SelectionState.annotation(annotation)

        XCTAssertNotEqual(region, annotationState)
    }

    // MARK: - Sendable Conformance Tests

    func testSelectionStateIsSendable() {
        // This test verifies that SelectionState can be used across actor boundaries
        // by creating it in a Task context
        let expectation = XCTestExpectation(description: "Sendable test")

        Task {
            let state = SelectionState.region(chromosome: "chr1", start: 0, end: 100)
            XCTAssertTrue(state.hasSelection)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Edge Cases

    func testRegionWithZeroCoordinates() {
        let state = SelectionState.region(chromosome: "chr1", start: 0, end: 0)

        XCTAssertTrue(state.hasSelection)
        XCTAssertEqual(state.selectionLength, 0)
    }

    func testRegionWithEmptyChromosomeName() {
        let state = SelectionState.region(chromosome: "", start: 0, end: 100)

        let region = state.selectedRegion
        XCTAssertNotNil(region)
        XCTAssertEqual(region?.chromosome, "")
    }

    func testAnnotationWithMinimalInterval() {
        let annotation = SequenceAnnotation(type: .snp, name: "SNP_001", start: 100, end: 101)
        let state = SelectionState.annotation(annotation)

        XCTAssertEqual(state.selectionLength, 1)
    }
}
