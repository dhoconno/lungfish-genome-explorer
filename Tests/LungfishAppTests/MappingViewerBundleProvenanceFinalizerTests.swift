import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class MappingViewerBundleProvenanceFinalizerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewerProvenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testPublishRefreshesMappingResultAndRecordsFinalViewerPayloads() throws {
        let fixture = try makeFixture()

        try MappingViewerBundlePublicationService.publish(
            result: fixture.preparedResult,
            resultDirectoryURL: fixture.resultDirectory,
            sourceReferenceBundleURL: fixture.sourceBundle,
            viewerBundleURL: fixture.viewerBundle
        )

        let storedResult = try MappingResult.load(from: fixture.resultDirectory)
        XCTAssertEqual(storedResult.viewerBundleURL?.standardizedFileURL, fixture.viewerBundle.standardizedFileURL)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.resultDirectory))
        let mappingResultURL = fixture.resultDirectory.appendingPathComponent("mapping-result.json")
        let mappingDescriptor = try XCTUnwrap(envelope.outputs.first { $0.path == mappingResultURL.path })
        XCTAssertEqual(mappingDescriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: mappingResultURL))
        XCTAssertEqual(mappingDescriptor.fileSize, try ProvenanceFileHasher.fileSize(of: mappingResultURL))

        let finalPayloadPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(finalPayloadPaths.contains(fixture.viewerBundle.path))
        XCTAssertTrue(finalPayloadPaths.contains(fixture.viewerBundle.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(finalPayloadPaths.contains(fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam").path))
        XCTAssertTrue(finalPayloadPaths.contains(fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam.bai").path))
        XCTAssertTrue(finalPayloadPaths.contains(fixture.viewerBundle.appendingPathComponent("alignments/viewer.stats.db").path))

        let publicationStep = try XCTUnwrap(envelope.steps.last)
        let expectedArgv = [
            "Lungfish.app",
            "prepare-mapping-viewer-bundle",
            "--mapping-result", fixture.resultDirectory.path,
            "--source-reference-bundle", fixture.sourceBundle.path,
            "--viewer-bundle", fixture.viewerBundle.path,
        ]
        XCTAssertEqual(publicationStep.toolName, "Lungfish.app")
        XCTAssertEqual(publicationStep.argv, expectedArgv)
        XCTAssertEqual(publicationStep.durableReplayArgv, expectedArgv)
        XCTAssertEqual(publicationStep.exitStatus, 0)
        let expectedInputPaths = Set([
            fixture.sourceBundle.path,
            fixture.sourceBundle.appendingPathComponent("manifest.json").path,
            fixture.sourceBundle.appendingPathComponent("genome/sequence.fa").path,
            fixture.sourceBundle.appendingPathComponent("genome/sequence.fa.fai").path,
            fixture.resultDirectory.appendingPathComponent("Sample.sorted.bam").path,
            fixture.resultDirectory.appendingPathComponent("Sample.sorted.bam.bai").path,
        ])
        XCTAssertEqual(Set(publicationStep.inputs.map(\.path)), expectedInputPaths)
        for input in publicationStep.inputs where input.path != fixture.sourceBundle.path {
            XCTAssertNotNil(input.checksumSHA256, "Missing checksum for \(input.path)")
            XCTAssertNotNil(input.fileSize, "Missing file size for \(input.path)")
        }
        XCTAssertEqual(Set(publicationStep.outputs.map(\.path)), Set([
            mappingResultURL.path,
            fixture.viewerBundle.path,
            fixture.viewerBundle.appendingPathComponent("manifest.json").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam.bai").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.stats.db").path,
        ]))
        XCTAssertFalse(envelope.files.contains { $0.path.contains("mapping-reference-stage") })
        XCTAssertTrue(envelope.signatures.isEmpty)
    }

    func testPublishRestoresOriginalSidecarsWhenViewerPayloadValidationFails() throws {
        let fixture = try makeFixture()
        let mappingResultURL = fixture.resultDirectory.appendingPathComponent("mapping-result.json")
        let canonicalURL = fixture.resultDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let originalResultData = try Data(contentsOf: mappingResultURL)
        let originalCanonicalData = try Data(contentsOf: canonicalURL)
        try FileManager.default.removeItem(at: fixture.viewerBundle.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publish(
                result: fixture.preparedResult,
                resultDirectoryURL: fixture.resultDirectory,
                sourceReferenceBundleURL: fixture.sourceBundle,
                viewerBundleURL: fixture.viewerBundle
            )
        )

        XCTAssertEqual(try Data(contentsOf: mappingResultURL), originalResultData)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), originalCanonicalData)
        XCTAssertNil(try MappingResult.load(from: fixture.resultDirectory).viewerBundleURL)
    }

    func testToolsMenuUsesTransactionalMappingViewerPublicationService() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("try MappingViewerBundlePublicationService.publish("))
    }

    private func makeFixture() throws -> (
        resultDirectory: URL,
        sourceBundle: URL,
        viewerBundle: URL,
        preparedResult: MappingResult
    ) {
        let resultDirectory = tempDirectory.appendingPathComponent("Sample", isDirectory: true)
        let sourceBundle = tempDirectory.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let viewerBundle = resultDirectory.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let viewerAlignments = viewerBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceBundle.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: viewerAlignments, withIntermediateDirectories: true)

        try ">chr1\nACGT\n".write(
            to: sourceBundle.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: sourceBundle.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )
        try BundleManifest(
            name: "Source",
            identifier: "org.lungfish.test.source",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)
                ]
            )
        ).save(to: sourceBundle)

        let bamURL = resultDirectory.appendingPathComponent("Sample.sorted.bam")
        let baiURL = resultDirectory.appendingPathComponent("Sample.sorted.bam.bai")
        try Data("mapping-bam".utf8).write(to: bamURL)
        try Data("mapping-index".utf8).write(to: baiURL)

        let initialResult = MappingResult(
            mapper: .minimap2,
            modeID: "short-read-default",
            sourceReferenceBundleURL: sourceBundle,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 5_633_919,
            mappedReads: 25,
            unmappedReads: 5_633_894,
            wallClockSeconds: 139.5,
            contigs: []
        )
        try initialResult.save(to: resultDirectory)

        let mappingResultURL = resultDirectory.appendingPathComponent("mapping-result.json")
        let bamDescriptor = try ProvenanceFileDescriptor.file(url: bamURL, format: .bam, role: .output)
        let baiDescriptor = try ProvenanceFileDescriptor.file(url: baiURL, role: .index)
        let staleResultDescriptor = try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: .json,
            role: .output
        )
        let mappingStep = ProvenanceStep(
            toolName: "minimap2",
            toolVersion: "2.30",
            argv: ["minimap2", "-a"],
            inputs: [],
            outputs: [bamDescriptor, baiDescriptor, staleResultDescriptor],
            exitStatus: 0
        )
        let initialEnvelope = ProvenanceEnvelope(
            workflowName: "lungfish map",
            toolName: "minimap2",
            toolVersion: "2.30",
            argv: ["minimap2", "-a"],
            files: [bamDescriptor, baiDescriptor, staleResultDescriptor],
            outputs: [bamDescriptor, baiDescriptor, staleResultDescriptor],
            steps: [mappingStep],
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(initialEnvelope, to: resultDirectory)

        try Data("viewer-bam".utf8).write(to: viewerAlignments.appendingPathComponent("viewer.bam"))
        try Data("viewer-index".utf8).write(to: viewerAlignments.appendingPathComponent("viewer.bam.bai"))
        try Data("viewer-stats".utf8).write(to: viewerAlignments.appendingPathComponent("viewer.stats.db"))
        let viewerManifest = BundleManifest(
            name: "Viewer",
            identifier: "org.lungfish.test.viewer",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln_viewer",
                    name: "Viewer BAM",
                    format: .bam,
                    sourcePath: "alignments/viewer.bam",
                    indexPath: "alignments/viewer.bam.bai",
                    metadataDBPath: "alignments/viewer.stats.db"
                )
            ]
        )
        try viewerManifest.save(to: viewerBundle)

        return (
            resultDirectory,
            sourceBundle,
            viewerBundle,
            initialResult.withViewerBundle(
                viewerBundleURL: viewerBundle,
                sourceReferenceBundleURL: sourceBundle
            )
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
