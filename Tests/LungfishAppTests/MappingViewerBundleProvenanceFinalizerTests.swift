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
        let expectedViewerPayloadPaths = Set([
            fixture.viewerBundle.path,
            fixture.viewerBundle.appendingPathComponent("manifest.json").path,
            fixture.viewerBundle.appendingPathComponent("genome/sequence.fa").path,
            fixture.viewerBundle.appendingPathComponent("genome/sequence.fa.fai").path,
            fixture.viewerBundle.appendingPathComponent("annotations/genes.bb").path,
            fixture.viewerBundle.appendingPathComponent("annotations/genes.sqlite").path,
            fixture.viewerBundle.appendingPathComponent("variants/calls.bcf").path,
            fixture.viewerBundle.appendingPathComponent("variants/calls.bcf.csi").path,
            fixture.viewerBundle.appendingPathComponent("variants/calls.sqlite").path,
            fixture.viewerBundle.appendingPathComponent("tracks/coverage.bw").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.bam.bai").path,
            fixture.viewerBundle.appendingPathComponent("alignments/viewer.stats.db").path,
        ])
        XCTAssertTrue(expectedViewerPayloadPaths.isSubset(of: finalPayloadPaths))

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
        XCTAssertNotNil(publicationStep.startedAt)
        XCTAssertNotNil(publicationStep.completedAt)
        XCTAssertNotNil(publicationStep.wallTimeSeconds)
        XCTAssertGreaterThanOrEqual(publicationStep.wallTimeSeconds ?? -1, 0)
        let expectedInputPaths = Set([
            fixture.sourceBundle.path,
            fixture.sourceBundle.appendingPathComponent("manifest.json").path,
            fixture.sourceBundle.appendingPathComponent("genome/sequence.fa").path,
            fixture.sourceBundle.appendingPathComponent("genome/sequence.fa.fai").path,
            fixture.sourceBundle.appendingPathComponent("annotations/genes.bb").path,
            fixture.sourceBundle.appendingPathComponent("annotations/genes.sqlite").path,
            fixture.sourceBundle.appendingPathComponent("variants/calls.bcf").path,
            fixture.sourceBundle.appendingPathComponent("variants/calls.bcf.csi").path,
            fixture.sourceBundle.appendingPathComponent("variants/calls.sqlite").path,
            fixture.sourceBundle.appendingPathComponent("tracks/coverage.bw").path,
            fixture.resultDirectory.appendingPathComponent("Sample.sorted.bam").path,
            fixture.resultDirectory.appendingPathComponent("Sample.sorted.bam.bai").path,
        ])
        XCTAssertEqual(Set(publicationStep.inputs.map(\.path)), expectedInputPaths)
        for input in publicationStep.inputs where input.path != fixture.sourceBundle.path {
            XCTAssertNotNil(input.checksumSHA256, "Missing checksum for \(input.path)")
            XCTAssertNotNil(input.fileSize, "Missing file size for \(input.path)")
        }
        XCTAssertEqual(Set(publicationStep.outputs.map(\.path)), expectedViewerPayloadPaths.union([mappingResultURL.path]))
        for output in publicationStep.outputs where output.path != fixture.viewerBundle.path {
            XCTAssertNotNil(output.checksumSHA256, "Missing checksum for \(output.path)")
            XCTAssertNotNil(output.fileSize, "Missing file size for \(output.path)")
        }
        XCTAssertFalse(envelope.files.contains { $0.path.contains("mapping-reference-stage") })
        XCTAssertTrue(envelope.signatures.isEmpty)
    }

    func testPublishRejectsViewerManifestPayloadOutsideFinalBundle() throws {
        let fixture = try makeFixture()
        let outsidePayload = fixture.resultDirectory.appendingPathComponent("outside.bb")
        try Data("outside".utf8).write(to: outsidePayload)
        try BundleManifest(
            name: "Unsafe Viewer",
            identifier: "org.lungfish.test.unsafe-viewer",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            annotations: [
                AnnotationTrackInfo(id: "unsafe", name: "Unsafe", path: "../outside.bb")
            ]
        ).save(to: fixture.viewerBundle)

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publish(
                result: fixture.preparedResult,
                resultDirectoryURL: fixture.resultDirectory,
                sourceReferenceBundleURL: fixture.sourceBundle,
                viewerBundleURL: fixture.viewerBundle
            )
        ) { error in
            guard case MappingViewerBundlePublicationError.invalidViewerPayloadPath(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "../outside.bb")
        }
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

        XCTAssertTrue(source.contains("try MappingViewerBundlePublicationService.publishCandidate("))
        XCTAssertFalse(source.contains("Reference viewer bundle could not be prepared"))
    }

    func testPublishCandidateRestoresExistingBundleWhenFinalizationFails() throws {
        let finalBundle = tempDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = tempDirectory.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: finalBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidateBundle, withIntermediateDirectories: true)
        let oldBytes = Data("old-viewer".utf8)
        try oldBytes.write(to: finalBundle.appendingPathComponent("sentinel"))
        try Data("new-viewer".utf8).write(to: candidateBundle.appendingPathComponent("sentinel"))

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidateBundle,
                finalBundleURL: finalBundle
            ) { _ in
                throw CandidatePublicationTestError.finalizationFailed
            }
        )

        XCTAssertEqual(try Data(contentsOf: finalBundle.appendingPathComponent("sentinel")), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateBundle.path))
    }

    func testPublishCandidateFirstTimeFailureLeavesNoPublishedBundle() throws {
        let finalBundle = tempDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = tempDirectory.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateBundle, withIntermediateDirectories: true)
        try Data("new-viewer".utf8).write(to: candidateBundle.appendingPathComponent("sentinel"))

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidateBundle,
                finalBundleURL: finalBundle
            ) { _ in
                throw CandidatePublicationTestError.finalizationFailed
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalBundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateBundle.path))
    }

    func testPublishCandidateAtomicallyReplacesExistingBundle() throws {
        let finalBundle = tempDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = tempDirectory.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: finalBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidateBundle, withIntermediateDirectories: true)
        try Data("old-viewer".utf8).write(to: finalBundle.appendingPathComponent("sentinel"))
        let newBytes = Data("new-viewer".utf8)
        try newBytes.write(to: candidateBundle.appendingPathComponent("sentinel"))

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundle,
            finalBundleURL: finalBundle
        ) { publishedBundle in
            XCTAssertEqual(try Data(contentsOf: publishedBundle.appendingPathComponent("sentinel")), newBytes)
        }

        XCTAssertEqual(try Data(contentsOf: finalBundle.appendingPathComponent("sentinel")), newBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateBundle.path))
    }

    func testPublishCandidateKeepsNewBundleAuthoritativeWhenOldBundleCleanupFails() throws {
        let finalBundle = tempDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = tempDirectory.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: finalBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidateBundle, withIntermediateDirectories: true)
        let oldBytes = Data("old-viewer".utf8)
        let newBytes = Data("new-viewer".utf8)
        try oldBytes.write(to: finalBundle.appendingPathComponent("sentinel"))
        try newBytes.write(to: candidateBundle.appendingPathComponent("sentinel"))
        let fileManager = RemoveFailingFileManager(failingURL: candidateBundle)

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundle,
            finalBundleURL: finalBundle,
            fileManager: fileManager
        ) { publishedBundle in
            XCTAssertEqual(try Data(contentsOf: publishedBundle.appendingPathComponent("sentinel")), newBytes)
        }

        XCTAssertEqual(try Data(contentsOf: finalBundle.appendingPathComponent("sentinel")), newBytes)
        XCTAssertEqual(try Data(contentsOf: candidateBundle.appendingPathComponent("sentinel")), oldBytes)
    }

    func testPublishCandidateRehydratesImportedBAMProvenanceToFinalPaths() throws {
        let finalBundle = tempDirectory.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = tempDirectory.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        let candidateAlignments = candidateBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateAlignments, withIntermediateDirectories: true)
        let candidateBAM = candidateAlignments.appendingPathComponent("viewer.bam")
        try Data("viewer-bam".utf8).write(to: candidateBAM)
        let descriptor = try ProvenanceFileDescriptor.file(url: candidateBAM, format: .bam, role: .output)
        let candidateDB = candidateAlignments.appendingPathComponent("viewer.stats.db")
        do {
            let database = try AlignmentMetadataDatabase.create(at: candidateDB)
            database.setFileInfo("source_path", value: candidateBAM.path)
            database.addProvenanceRecord(
                tool: "lungfish",
                subcommand: "import-bam",
                command: "import viewer.bam",
                inputFile: candidateBAM.path,
                outputFile: candidateDB.path,
                exitCode: 0
            )
        }
        let databaseDescriptor = try ProvenanceFileDescriptor.file(
            url: candidateDB,
            format: .sqlite,
            role: .output
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "BAM import",
            toolName: "Lungfish.app",
            argv: ["import-bam", candidateBAM.path],
            durableReplayArgv: ["import-bam", candidateBAM.path],
            options: ProvenanceOptions(
                explicit: ["bundle": .file(candidateBundle)],
                resolvedDefaults: ["bam": .string(candidateBAM.path)]
            ),
            files: [descriptor, databaseDescriptor],
            output: descriptor,
            outputs: [descriptor, databaseDescriptor],
            steps: [
                ProvenanceStep(
                    toolName: "Lungfish.app",
                    argv: ["import-bam", candidateBAM.path],
                    durableReplayArgv: ["import-bam", candidateBAM.path],
                    resolvedOptions: ["bundle": .file(candidateBundle)],
                    outputs: [descriptor],
                    exitStatus: 0
                )
            ],
            exitStatus: 0
        )
        let sidecar = candidateAlignments.appendingPathComponent("viewer.import.lungfish-provenance.json")
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecar)

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundle,
            finalBundleURL: finalBundle
        ) { publishedBundle in
            let publishedSidecar = publishedBundle
                .appendingPathComponent("alignments/viewer.import.lungfish-provenance.json")
            let published = try ProvenanceJSON.decoder.decode(
                ProvenanceEnvelope.self,
                from: Data(contentsOf: publishedSidecar)
            )
            let finalBAM = publishedBundle.appendingPathComponent("alignments/viewer.bam")
            XCTAssertEqual(published.output?.path, finalBAM.path)
            XCTAssertEqual(published.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: finalBAM))
            XCTAssertEqual(published.output?.fileSize, try ProvenanceFileHasher.fileSize(of: finalBAM))
            XCTAssertEqual(published.argv, ["import-bam", finalBAM.path])
            XCTAssertEqual(published.durableReplayArgv, ["import-bam", finalBAM.path])
            XCTAssertEqual(published.options.explicit["bundle"], .file(publishedBundle))
            XCTAssertEqual(published.options.resolvedDefaults["bam"], .string(finalBAM.path))
            XCTAssertEqual(published.steps.first?.outputs.first?.path, finalBAM.path)
            let finalDB = publishedBundle.appendingPathComponent("alignments/viewer.stats.db")
            let metadata = try AlignmentMetadataDatabase(url: finalDB)
            XCTAssertEqual(metadata.getFileInfo("source_path"), finalBAM.path)
            XCTAssertEqual(metadata.provenanceHistory().first?.inputFile, finalBAM.path)
            XCTAssertEqual(metadata.provenanceHistory().first?.outputFile, finalDB.path)
            let publishedDatabaseDescriptor = try XCTUnwrap(
                published.outputs.first { $0.path == finalDB.path }
            )
            XCTAssertEqual(
                publishedDatabaseDescriptor.checksumSHA256,
                try ProvenanceFileHasher.sha256(of: finalDB)
            )
            XCTAssertEqual(
                publishedDatabaseDescriptor.fileSize,
                try ProvenanceFileHasher.fileSize(of: finalDB)
            )
            XCTAssertFalse(String(decoding: try Data(contentsOf: publishedSidecar), as: UTF8.self).contains(candidateBundle.path))
            XCTAssertTrue(published.signatures.isEmpty)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateBundle.path))
    }

    func testPublishCandidateRestoresExistingViewerAndResultSidecarsWhenFinalizationFails() throws {
        let fixture = try makeFixture()
        let candidateBundle = fixture.resultDirectory.appendingPathComponent(
            ".Viewer.candidate.lungfishref",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.viewerBundle, to: candidateBundle)
        try FileManager.default.removeItem(at: candidateBundle.appendingPathComponent("manifest.json"))

        try FileManager.default.createDirectory(at: fixture.viewerBundle, withIntermediateDirectories: true)
        let oldPayload = Data("old-viewer-payload".utf8)
        let oldProvenance = Data("old-viewer-provenance".utf8)
        try oldPayload.write(to: fixture.viewerBundle.appendingPathComponent("sentinel"))
        try oldProvenance.write(
            to: fixture.viewerBundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        )

        let sidecarURLs = [
            fixture.resultDirectory.appendingPathComponent("mapping-result.json"),
            fixture.resultDirectory.appendingPathComponent(MappingProvenance.filename),
            fixture.resultDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename),
        ]
        let originalSidecars = try sidecarURLs.map {
            ($0, FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil)
        }

        XCTAssertThrowsError(
            try MappingViewerBundlePublicationService.publishCandidate(
                candidateBundleURL: candidateBundle,
                finalBundleURL: fixture.viewerBundle
            ) { publishedBundle in
                try MappingViewerBundlePublicationService.publish(
                    result: fixture.preparedResult,
                    resultDirectoryURL: fixture.resultDirectory,
                    sourceReferenceBundleURL: fixture.sourceBundle,
                    viewerBundleURL: publishedBundle
                )
            }
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.viewerBundle.appendingPathComponent("sentinel")),
            oldPayload
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.viewerBundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)),
            oldProvenance
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateBundle.path))
        for (url, expected) in originalSidecars {
            if let expected {
                XCTAssertEqual(try Data(contentsOf: url), expected, "Changed sidecar: \(url.path)")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Created sidecar: \(url.path)")
            }
        }
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

        let sharedPayloads: [(String, String)] = [
            ("genome/sequence.fa", ">chr1\nACGT\n"),
            ("genome/sequence.fa.fai", "chr1\t4\t6\t4\t5\n"),
            ("annotations/genes.bb", "bigbed"),
            ("annotations/genes.sqlite", "annotation-db"),
            ("variants/calls.bcf", "bcf"),
            ("variants/calls.bcf.csi", "csi"),
            ("variants/calls.sqlite", "variant-db"),
            ("tracks/coverage.bw", "bigwig"),
        ]
        for bundle in [sourceBundle, viewerBundle] {
            for (relativePath, contents) in sharedPayloads {
                let url = bundle.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(contents.utf8).write(to: url)
            }
        }

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
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb",
                    databasePath: "annotations/genes.sqlite"
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "calls",
                    name: "Calls",
                    path: "variants/calls.bcf",
                    indexPath: "variants/calls.bcf.csi",
                    databasePath: "variants/calls.sqlite"
                )
            ],
            tracks: [
                SignalTrackInfo(id: "coverage", name: "Coverage", path: "tracks/coverage.bw")
            ]
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
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb",
                    databasePath: "annotations/genes.sqlite"
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "calls",
                    name: "Calls",
                    path: "variants/calls.bcf",
                    indexPath: "variants/calls.bcf.csi",
                    databasePath: "variants/calls.sqlite"
                )
            ],
            tracks: [
                SignalTrackInfo(id: "coverage", name: "Coverage", path: "tracks/coverage.bw")
            ],
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

    private enum CandidatePublicationTestError: Error {
        case finalizationFailed
    }

    private final class RemoveFailingFileManager: FileManager {
        private let failingPath: String

        init(failingURL: URL) {
            failingPath = failingURL.standardizedFileURL.path
            super.init()
        }

        override func removeItem(at URL: URL) throws {
            if URL.standardizedFileURL.path == failingPath {
                throw CandidatePublicationTestError.finalizationFailed
            }
            try super.removeItem(at: URL)
        }
    }
}
