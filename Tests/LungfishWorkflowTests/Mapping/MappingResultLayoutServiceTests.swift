// MappingResultLayoutServiceTests.swift - The shared window/CLI mapping result layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MappingResultLayoutServiceTests: XCTestCase {
    private var scaffolds: [MappingResultLayoutScaffold] = []

    override func tearDown() {
        scaffolds.forEach { $0.cleanUp() }
        scaffolds = []
        super.tearDown()
    }

    /// The layout the Map Reads window leaves in a project, produced by the
    /// service both surfaces call.
    static let expectedLayout: [String] = [
        ".lungfish-provenance.json",
        "analysis-metadata.json",
        "mapping-provenance.json",
        "mapping-result.json",
        "sample.sorted.bam",
        "sample.sorted.bam.bai",
        "src.lungfishref",
        "src.lungfishref/alignments",
        "src.lungfishref/alignments/aln_*.import.lungfish-provenance.json",
        "src.lungfishref/alignments/aln_*.sorted.bam",
        "src.lungfishref/alignments/aln_*.sorted.bam.bai",
        "src.lungfishref/alignments/aln_*.stats.db",
        "src.lungfishref/genome",
        "src.lungfishref/genome/sequence.fa",
        "src.lungfishref/genome/sequence.fa.fai",
        "src.lungfishref/manifest.json",
    ]

    func testDefaultTrackNameAndAnalysisDirectory() throws {
        XCTAssertEqual(MappingResultLayoutService.defaultTrackName(for: .minimap2), "minimap2 Mapping")
        XCTAssertEqual(MappingResultLayoutService.defaultTrackName(for: .bwaMem2), "BWA-MEM2 Mapping")

        let scaffold = try makeScaffold()
        XCTAssertEqual(scaffold.analysisDirectoryURL.deletingLastPathComponent().lastPathComponent, "Analyses")
        XCTAssertTrue(scaffold.analysisDirectoryURL.lastPathComponent.hasPrefix("minimap2-"))
        let metadata = try XCTUnwrap(AnalysesFolder.readAnalysisMetadata(from: scaffold.analysisDirectoryURL))
        XCTAssertEqual(metadata.tool, "minimap2")
        XCTAssertFalse(metadata.isBatch)

        XCTAssertEqual(MappingResultLayoutService.trackName(for: scaffold.request), "minimap2 Mapping")
        XCTAssertEqual(
            MappingResultLayoutService.trackName(for: scaffold.request.withOutputTrackName("HG002 minimap2")),
            "HG002 minimap2"
        )
        XCTAssertEqual(
            MappingResultLayoutService.trackName(for: scaffold.request.withOutputTrackName("   ")),
            "minimap2 Mapping"
        )
    }

    func testPublishViewerBundleProducesTheWindowLayout() async throws {
        try await skipUnlessSamtoolsIsInstalled()
        let scaffold = try makeScaffold()

        let publishedOrNil = try await MappingResultLayoutService.publishViewerBundle(
            result: scaffold.result,
            request: scaffold.request
        )
        let publication = try XCTUnwrap(publishedOrNil)

        // The copy of the reference bundle sits inside the analysis folder
        // under the source bundle's own name, with one attached track.
        XCTAssertEqual(
            publication.viewerBundleURL.standardizedFileURL,
            scaffold.analysisDirectoryURL.appendingPathComponent("src.lungfishref").standardizedFileURL
        )
        XCTAssertEqual(publication.sourceReferenceBundleURL.standardizedFileURL, scaffold.sourceBundleURL.standardizedFileURL)
        let manifest = try BundleManifest.load(from: publication.viewerBundleURL)
        XCTAssertEqual(manifest.alignments.map(\.name), ["minimap2 Mapping"])
        // `addedDate` loses sub-second precision in the manifest, so compare
        // the identifying fields rather than the whole value.
        XCTAssertEqual(manifest.alignments.first?.id, publication.trackInfo.id)
        XCTAssertEqual(manifest.alignments.first?.sourcePath, publication.trackInfo.sourcePath)
        XCTAssertEqual(manifest.alignments.first?.indexPath, publication.trackInfo.indexPath)
        XCTAssertEqual(manifest.alignments.first?.metadataDBPath, publication.trackInfo.metadataDBPath)
        XCTAssertEqual(manifest.originBundlePath, "@/Reference Sequences/src.lungfishref")
        XCTAssertTrue(publication.trackInfo.sourcePath.hasPrefix("alignments/aln_"))
        XCTAssertTrue(publication.trackInfo.sourcePath.hasSuffix(".sorted.bam"))

        // The sidecars point at the copy.
        let storedResult = try MappingResult.load(from: scaffold.analysisDirectoryURL)
        XCTAssertEqual(storedResult.viewerBundleURL?.standardizedFileURL, publication.viewerBundleURL.standardizedFileURL)
        XCTAssertEqual(storedResult.sourceReferenceBundleURL?.standardizedFileURL, scaffold.sourceBundleURL.standardizedFileURL)
        XCTAssertEqual(storedResult, publication.result)
        let provenance = try XCTUnwrap(MappingProvenance.load(from: scaffold.analysisDirectoryURL))
        XCTAssertEqual(provenance.viewerBundlePath, publication.viewerBundleURL.standardizedFileURL.path)
        XCTAssertEqual(provenance.sourceReferenceBundlePath, scaffold.sourceBundleURL.standardizedFileURL.path)
        let resultSidecar = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: scaffold.analysisDirectoryURL.appendingPathComponent("mapping-result.json"))
        ) as? [String: Any])
        XCTAssertEqual(resultSidecar["viewerBundlePath"] as? String, "src.lungfishref")
        XCTAssertEqual(resultSidecar["sourceReferenceBundlePath"] as? String, "@/Reference Sequences/src.lungfishref")

        XCTAssertEqual(
            try MappingResultLayoutScaffold.normalizedLayout(of: scaffold.analysisDirectoryURL, tool: .minimap2),
            Self.expectedLayout
        )
    }

    // The mapper's BAM at the result root is already coordinate-sorted and
    // indexed, so the viewer copy is an APFS clone of it (same bytes, shared
    // blocks) rather than a second `samtools sort` that stored the BAM twice
    // in full. The layout (root BAM plus in-bundle track) is unchanged.
    func testViewerBundleTrackIsACloneOfTheRootBAMNotASecondSort() async throws {
        try await skipUnlessSamtoolsIsInstalled()
        let scaffold = try makeScaffold()

        let publishedOrNil = try await MappingResultLayoutService.publishViewerBundle(
            result: scaffold.result,
            request: scaffold.request
        )
        let publication = try XCTUnwrap(publishedOrNil)

        let trackBAM = publication.viewerBundleURL.appendingPathComponent(publication.trackInfo.sourcePath)
        let trackBAI = publication.viewerBundleURL.appendingPathComponent(publication.trackInfo.indexPath)
        XCTAssertEqual(try Data(contentsOf: trackBAM), try Data(contentsOf: scaffold.result.bamURL))
        XCTAssertEqual(try Data(contentsOf: trackBAI), try Data(contentsOf: scaffold.result.baiURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scaffold.result.bamURL.path), "the root BAM stays")

        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            publication.viewerBundleURL.appendingPathComponent("alignments/\(publication.trackInfo.id).import.lungfish-provenance.json")
        )) as? [String: Any])
        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        let argvs = steps.compactMap { $0["argv"] as? [String] }
        XCTAssertTrue(argvs.contains { $0.contains("--clone-sorted-alignment") }, "provenance records the clone: \(argvs)")
        XCTAssertFalse(argvs.contains { $0.contains("sort") && $0.first?.contains("samtools") == true }, "no second sort: \(argvs)")
    }

    func testExplicitTrackNameIsAttachedAndRecorded() async throws {
        try await skipUnlessSamtoolsIsInstalled()
        let scaffold = try makeScaffold(outputTrackName: "HG002 minimap2")

        let publishedOrNil = try await MappingResultLayoutService.publishViewerBundle(
            result: scaffold.result,
            request: scaffold.request
        )
        let publication = try XCTUnwrap(publishedOrNil)
        XCTAssertEqual(publication.trackInfo.name, "HG002 minimap2")
        XCTAssertEqual(try BundleManifest.load(from: publication.viewerBundleURL).alignments.map(\.name), ["HG002 minimap2"])

        // The run's own provenance carries the requested name, and the
        // summary the analysis history records names the resolved track.
        let provenance = try XCTUnwrap(MappingProvenance.load(from: scaffold.analysisDirectoryURL))
        XCTAssertEqual(provenance.parameters.outputTrackName, "HG002 minimap2")
        XCTAssertEqual(scaffold.request.summaryParameters()["outputTrackName"], .string("HG002 minimap2"))
        XCTAssertNil(try XCTUnwrap(MappingProvenance.load(from: makeScaffold().analysisDirectoryURL)).parameters.outputTrackName)
    }

    func testPublishViewerBundleIsSkippedWhenTheReferenceIsNotABundle() async throws {
        let scaffold = try makeScaffold()
        let looseReference = scaffold.projectRootURL.appendingPathComponent("loose.fa")
        try Data(">chr\nACGT\n".utf8).write(to: looseReference)
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.rawValue,
            inputFASTQURLs: scaffold.request.inputFASTQURLs,
            referenceFASTAURL: looseReference,
            projectURL: scaffold.projectRootURL,
            outputDirectory: scaffold.analysisDirectoryURL,
            sampleName: "sample",
            threads: 1
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: scaffold.result.bamURL,
            baiURL: scaffold.result.baiURL,
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        let publication = try await MappingResultLayoutService.publishViewerBundle(result: result, request: request)
        XCTAssertNil(publication)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scaffold.analysisDirectoryURL.appendingPathComponent("src.lungfishref").path
        ))
    }

    func testAnalysisManifestIsRecordedInTheReadsBundle() throws {
        let scaffold = try makeScaffold()
        let recordedBundle = try MappingResultLayoutService.recordAnalysisManifest(
            originalInputURLs: scaffold.request.inputFASTQURLs,
            resolvedRequest: scaffold.request,
            result: scaffold.result,
            projectURL: scaffold.projectRootURL
        )
        XCTAssertEqual(recordedBundle?.standardizedFileURL, scaffold.fastqBundleURL.standardizedFileURL)
        let manifest = AnalysisManifestStore.load(bundleURL: scaffold.fastqBundleURL, projectURL: scaffold.projectRootURL)
        let entry = try XCTUnwrap(manifest.analyses.first)
        XCTAssertEqual(entry.tool, "minimap2")
        XCTAssertEqual(entry.displayName, "minimap2 Mapping")
        XCTAssertEqual(entry.summary, "1/1 reads mapped")
        // The same name AppDelegate records: what AnalysisManifestStore
        // derives for a directory inside the project's Analyses folder.
        XCTAssertEqual(
            entry.analysisDirectoryName,
            MappingResultLayoutService.analysisManifestDirectoryName(
                for: scaffold.analysisDirectoryURL,
                projectURL: scaffold.projectRootURL
            )
        )
        XCTAssertEqual(entry.analysisDirectoryName, scaffold.analysisDirectoryURL.lastPathComponent)
        XCTAssertEqual(entry.parameters["outputTrackName"], .string("minimap2 Mapping"))

        XCTAssertNil(MappingResultLayoutService.findSourceBundle(for: [scaffold.projectRootURL.appendingPathComponent("loose.fq")]))
    }

    // MARK: - Helpers

    private func makeScaffold(outputTrackName: String? = nil) throws -> MappingResultLayoutScaffold {
        let fixtureBAM = packageRoot().appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: fixtureBAM.path) else {
            throw XCTSkip("sarscov2 BAM fixture missing at \(fixtureBAM.path)")
        }
        let scaffold = try MappingResultLayoutScaffold.make(fixtureBAMURL: fixtureBAM, outputTrackName: outputTrackName)
        scaffolds.append(scaffold)
        return scaffold
    }

    private func skipUnlessSamtoolsIsInstalled() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            throw XCTSkip("samtools is not installed in the managed conda root: \(error.localizedDescription)")
        }
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
