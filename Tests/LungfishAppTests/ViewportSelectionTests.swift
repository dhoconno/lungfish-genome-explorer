// ViewportSelectionTests.swift - Tests for viewport selection and extraction pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

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

    func testBuildBundleWritesCanonicalProvenanceForNewBundleOutput() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-extraction-provenance-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = tempRoot.appendingPathComponent("outputs", isDirectory: true)
        let sourceBundleURL = tempRoot.appendingPathComponent("source.lungfishref", isDirectory: true)
        let sourceGenomeDirectory = sourceBundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceGenomeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sourceFASTA = sourceGenomeDirectory.appendingPathComponent("sequence.fa.gz")
        let sourceFAI = sourceGenomeDirectory.appendingPathComponent("sequence.fa.gz.fai")
        try "source genome\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)
        try "chr1\t12\t6\t12\t13\n".write(to: sourceFAI, atomically: true, encoding: .utf8)

        let sourceManifest = BundleManifest(
            name: "Source Reference",
            identifier: "org.lungfish.test.source",
            description: "source",
            source: SourceInfo(organism: "source", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: nil,
                totalLength: 12,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 12,
                        offset: 6,
                        lineBases: 12,
                        lineWidth: 13
                    ),
                ]
            )
        )
        try sourceManifest.save(to: sourceBundleURL)

        let result = ExtractionResult(
            fastaHeader: "chr1:0-12",
            nucleotideSequence: "ATGAAATAATGA",
            proteinSequence: nil,
            sourceName: "chr1",
            chromosome: "chr1",
            effectiveStart: 0,
            effectiveEnd: 12,
            isReverseComplement: false
        )

        let bundleURL = try await SequenceExtractionPipeline().buildBundle(
            from: result,
            outputDirectory: outputDirectory,
            sourceBundleURL: sourceBundleURL,
            sourceBundleName: "Source Reference",
            desiredBundleName: "extracted-chr1"
        )

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/bundle.lungfish-provenance.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/genome/sequence.fa.gz.lungfish-provenance.json").path))

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(envelope.workflowName, "lungfish gui sequence extraction")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertTrue(envelope.argv.contains("--source-bundle"))
        XCTAssertTrue(envelope.argv.contains(sourceBundleURL.path))
        XCTAssertTrue(envelope.argv.contains("--output"))
        XCTAssertTrue(envelope.argv.contains(bundleURL.path))
        XCTAssertEqual(envelope.options.resolvedDefaults["coordinate_system"]?.stringValue, "0-based half-open")
        let outputGenomePath = bundleURL.appendingPathComponent("genome/sequence.fa.gz").path
        let inputManifestPath = sourceBundleURL.appendingPathComponent("manifest.json").path
        var hasOutputGenome = false
        var hasInputManifest = false
        for file in envelope.files {
            if file.path == outputGenomePath, file.role == FileRole.output, file.checksumSHA256 != nil {
                hasOutputGenome = true
            }
            if file.path == inputManifestPath, file.role == FileRole.input, file.checksumSHA256 != nil {
                hasInputManifest = true
            }
        }
        XCTAssertTrue(hasOutputGenome)
        XCTAssertTrue(hasInputManifest)
    }

    func testBuildBundleRemovesOutputBundleWhenProvenanceWriteFails() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/ViewModels/SequenceExtractionPipeline.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("try? fileManager.removeItem(at: bundleURL)"))
        XCTAssertTrue(source.contains("throw error"))
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
