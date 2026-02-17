// ViewportSelectionTests.swift - Tests for viewport selection and extraction pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

// MARK: - SequenceExtractionPipeline Configuration Tests

final class SequenceExtractionPipelineConfigTests: XCTestCase {

    func testSourceAnnotationTrackInit() {
        let track = SequenceExtractionPipeline.SourceAnnotationTrack(
            id: "track1",
            name: "Gene Annotations",
            databaseURL: URL(fileURLWithPath: "/tmp/annotations.db"),
            annotationType: .gene
        )
        XCTAssertEqual(track.id, "track1")
        XCTAssertEqual(track.name, "Gene Annotations")
        XCTAssertEqual(track.annotationType, .gene)
    }

    func testSourceVariantTrackInit() {
        let track = SequenceExtractionPipeline.SourceVariantTrack(
            id: "vcf1",
            name: "Sample Variants",
            databaseURL: URL(fileURLWithPath: "/tmp/variants.db"),
            variantType: .snp
        )
        XCTAssertEqual(track.id, "vcf1")
        XCTAssertEqual(track.name, "Sample Variants")
        XCTAssertEqual(track.variantType, .snp)
    }

    func testSourceAnnotationTrackIsSendable() {
        // Verify SourceAnnotationTrack conforms to Sendable by passing through a closure
        let track = SequenceExtractionPipeline.SourceAnnotationTrack(
            id: "track1",
            name: "Test",
            databaseURL: URL(fileURLWithPath: "/tmp/test.db"),
            annotationType: .transcript
        )
        let sendableCheck: @Sendable () -> String = { track.id }
        XCTAssertEqual(sendableCheck(), "track1")
    }

    func testSourceVariantTrackIsSendable() {
        let track = SequenceExtractionPipeline.SourceVariantTrack(
            id: "vcf1",
            name: "Test",
            databaseURL: URL(fileURLWithPath: "/tmp/test.db"),
            variantType: .indel
        )
        let sendableCheck: @Sendable () -> String = { track.id }
        XCTAssertEqual(sendableCheck(), "vcf1")
    }
}

// MARK: - SampleDisplayState Visible Filter Tests

final class SampleDisplayStateFilterTests: XCTestCase {

    func testVisibleSamplesWithNoHidden() {
        let state = SampleDisplayState()
        let all = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: all)
        XCTAssertEqual(visible, ["S1", "S2", "S3"])
    }

    func testVisibleSamplesWithHiddenSamples() {
        var state = SampleDisplayState()
        state.hiddenSamples = Set(["S2"])
        let all = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: all)
        XCTAssertEqual(visible, ["S1", "S3"])
    }

    func testVisibleSamplesAllHidden() {
        var state = SampleDisplayState()
        state.hiddenSamples = Set(["S1", "S2", "S3"])
        let all = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: all)
        XCTAssertTrue(visible.isEmpty)
    }

    func testVisibleSamplesPreservesOrder() {
        var state = SampleDisplayState()
        state.hiddenSamples = Set(["S2"])
        let all = ["S3", "S1", "S2", "S4"]
        let visible = state.visibleSamples(from: all)
        XCTAssertEqual(visible, ["S3", "S1", "S4"])
    }

    func testVisibleSamplesWithExplicitOrder() {
        var state = SampleDisplayState()
        state.sampleOrder = ["S3", "S1", "S2"]
        let all = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: all)
        XCTAssertEqual(visible, ["S3", "S1", "S2"])
    }

    func testVisibleSamplesWithOrderAndHidden() {
        var state = SampleDisplayState()
        state.sampleOrder = ["S3", "S1", "S2"]
        state.hiddenSamples = Set(["S1"])
        let all = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: all)
        XCTAssertEqual(visible, ["S3", "S2"])
    }
}

// MARK: - Menu Validation Tests

@MainActor
final class MenuValidationTests: XCTestCase {

    func testSequenceMenuActionsProtocolHasExtractSelection() {
        // Verify the protocol has the extractSelection method via selector
        let selector = #selector(SequenceMenuActions.extractSelection(_:))
        XCTAssertNotNil(selector)
    }

    func testSequenceMenuActionsProtocolHasCopySelectionFASTA() {
        let selector = #selector(SequenceMenuActions.copySelectionFASTA(_:))
        XCTAssertNotNil(selector)
    }
}

// MARK: - ExtractionConfiguration Tests

final class ExtractionConfigurationOutputModeTests: XCTestCase {

    func testNewBundleOutputMode() {
        let config = ExtractionConfiguration(
            flank5Prime: 0,
            flank3Prime: 0,
            reverseComplement: false,
            concatenateExons: false,
            outputMode: .newBundle,
            bundleName: "Test Bundle"
        )
        XCTAssertEqual(config.outputMode, .newBundle)
        XCTAssertEqual(config.bundleName, "Test Bundle")
    }

    func testClipboardNucleotideOutputMode() {
        let config = ExtractionConfiguration(
            flank5Prime: 100,
            flank3Prime: 50,
            reverseComplement: false,
            concatenateExons: false,
            outputMode: .clipboardNucleotide,
            bundleName: ""
        )
        XCTAssertEqual(config.outputMode, .clipboardNucleotide)
        XCTAssertEqual(config.flank5Prime, 100)
        XCTAssertEqual(config.flank3Prime, 50)
    }

    func testExtractionOutputModeAllCases() {
        let cases = ExtractionOutputMode.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.clipboardNucleotide))
        XCTAssertTrue(cases.contains(.clipboardProtein))
        XCTAssertTrue(cases.contains(.newBundle))
    }
}
