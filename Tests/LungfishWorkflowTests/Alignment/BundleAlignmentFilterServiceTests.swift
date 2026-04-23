import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class BundleAlignmentFilterServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleAlignmentFilterServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBundleTargetWritesFilteredTrackIntoFilteredDirectoryAndRecordsDerivationMetadata() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let service = fixture.makeService()

        let result = try await service.deriveFilteredAlignment(
            target: .bundle(fixture.bundleURL),
            sourceTrackID: fixture.sourceTrackID,
            outputTrackName: "Exact Match Reads",
            filterRequest: AlignmentFilterRequest(mappedOnly: true, identityFilter: .exactMatch)
        )

        XCTAssertEqual(result.bundleURL, fixture.bundleURL)
        XCTAssertNil(result.mappingResultURL)
        XCTAssertEqual(result.trackInfo.id, fixture.derivedTrackID)
        XCTAssertEqual(result.trackInfo.sourcePath, "alignments/filtered/\(fixture.derivedTrackID).bam")
        XCTAssertEqual(result.trackInfo.indexPath, "alignments/filtered/\(fixture.derivedTrackID).bam.bai")
        XCTAssertEqual(result.trackInfo.metadataDBPath, "alignments/filtered/\(fixture.derivedTrackID).stats.db")
        XCTAssertEqual(result.trackInfo.mappedReadCount, 7)
        XCTAssertEqual(result.trackInfo.unmappedReadCount, 5)
        XCTAssertEqual(result.trackInfo.sampleNames, ["sample-1"])
        XCTAssertEqual(result.commandHistory.map(\.subcommand), ["view", "sort", "index"])

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(manifest.alignments.contains(where: { $0.id == fixture.derivedTrackID }))

        let metadataURL = fixture.bundleURL.appendingPathComponent(try XCTUnwrap(result.trackInfo.metadataDBPath))
        let db = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(db.getFileInfo("source_path_in_bundle"), result.trackInfo.sourcePath)
        XCTAssertEqual(db.getFileInfo("derivation_kind"), "filtered_alignment")
        XCTAssertEqual(db.getFileInfo("derivation_source_track_id"), fixture.sourceTrackID)
        XCTAssertEqual(db.getFileInfo("derivation_duplicate_mode"), "none")
        XCTAssertEqual(db.getFileInfo("derivation_target_kind"), "bundle")
        XCTAssertEqual(db.getFileInfo("mapped_reads"), "7")
        XCTAssertEqual(db.getFileInfo("unmapped_reads"), "5")
        XCTAssertEqual(db.sampleNames(), ["sample-1"])
        XCTAssertEqual(db.provenanceHistory().map(\.subcommand), ["view", "sort", "index"])
    }

    func testMappingResultTargetResolvesViewerBundle() async throws {
        let fixture = try AlignmentFilterFixture.makeMappingResult(
            rootURL: tempDir,
            includeViewerBundle: true,
            includeNMTag: true
        )
        let service = fixture.makeService()

        let result = try await service.deriveFilteredAlignment(
            target: .mappingResult(try XCTUnwrap(fixture.mappingResultURL)),
            sourceTrackID: fixture.sourceTrackID,
            outputTrackName: "Mapped Reads",
            filterRequest: AlignmentFilterRequest(mappedOnly: true)
        )

        XCTAssertEqual(result.bundleURL, fixture.bundleURL)
        XCTAssertEqual(result.mappingResultURL, fixture.mappingResultURL)
    }

    func testMappingResultTargetFailsClearlyWhenViewerBundleIsMissing() async throws {
        let fixture = try AlignmentFilterFixture.makeMappingResult(
            rootURL: tempDir,
            includeViewerBundle: false,
            includeNMTag: true
        )
        let service = fixture.makeService()

        await XCTAssertThrowsErrorAsync(
            try await service.deriveFilteredAlignment(
                target: .mappingResult(try XCTUnwrap(fixture.mappingResultURL)),
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads",
                filterRequest: AlignmentFilterRequest(mappedOnly: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? AlignmentFilterTargetResolverError,
                .missingViewerBundle(try! XCTUnwrap(fixture.mappingResultURL))
            )
        }
    }

    func testIdentityFilterFailsWhenNmTagIsMissing() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: false)
        let service = fixture.makeService()

        await XCTAssertThrowsErrorAsync(
            try await service.deriveFilteredAlignment(
                target: .bundle(fixture.bundleURL),
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Exact Match Reads",
                filterRequest: AlignmentFilterRequest(identityFilter: .exactMatch)
            )
        ) { error in
            XCTAssertEqual(
                error as? BundleAlignmentFilterServiceError,
                .missingRequiredSAMTags(["NM"], sourceTrackID: fixture.sourceTrackID)
            )
        }
    }

    func testRemoveDuplicatesRunsMarkdupPreprocessingBeforeFiltering() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let service = fixture.makeService()

        let result = try await service.deriveFilteredAlignment(
            target: .bundle(fixture.bundleURL),
            sourceTrackID: fixture.sourceTrackID,
            outputTrackName: "Removed Duplicates",
            filterRequest: AlignmentFilterRequest(
                duplicateMode: .remove,
                identityFilter: .minimumPercentIdentity(99)
            )
        )

        let invocations = await fixture.markdupPipeline.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].inputURL, fixture.sourceBAMURL)
        XCTAssertFalse(invocations[0].removeDuplicates)
        XCTAssertEqual(result.commandHistory.first?.subcommand, "markdup")

        let metadataURL = fixture.bundleURL.appendingPathComponent(try XCTUnwrap(result.trackInfo.metadataDBPath))
        let db = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(db.getFileInfo("derivation_duplicate_mode"), "remove")
        XCTAssertEqual(
            db.getFileInfo("derivation_preprocessing"),
            "samtools markdup(removeDuplicates=false)"
        )
        XCTAssertEqual(db.provenanceHistory().first?.subcommand, "markdup")
    }

    func testPreparedAttachmentRejectsTraversingRelativeDirectory() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let staged = try makeStagedAlignmentArtifacts(named: "traversal")
        let service = PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector)
        let escapedURL = fixture.bundleURL
            .appendingPathComponent("alignments/filtered/../../escaped.bam")
            .standardizedFileURL

        await XCTAssertThrowsErrorAsync(
            try await service.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: fixture.bundleURL,
                    stagedBAMURL: staged.bamURL,
                    stagedIndexURL: staged.indexURL,
                    outputTrackID: "safe-track",
                    outputTrackName: "Traversal",
                    relativeDirectory: "alignments/filtered/../../outside"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlignmentAttachmentError,
                .invalidRelativeDirectory("alignments/filtered/../../outside")
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testPreparedAttachmentRejectsMalformedOutputTrackID() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let staged = try makeStagedAlignmentArtifacts(named: "trackid")
        let service = PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector)
        let escapedURL = fixture.bundleURL
            .appendingPathComponent("alignments/evil.bam")
            .standardizedFileURL

        await XCTAssertThrowsErrorAsync(
            try await service.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: fixture.bundleURL,
                    stagedBAMURL: staged.bamURL,
                    stagedIndexURL: staged.indexURL,
                    outputTrackID: "../evil",
                    outputTrackName: "Bad Track ID",
                    relativeDirectory: "alignments/filtered"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlignmentAttachmentError,
                .invalidOutputTrackID("../evil")
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testPreparedAttachmentRejectsSAMFormat() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let staged = try makeStagedAlignmentArtifacts(named: "sam")
        let service = PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector)

        await XCTAssertThrowsErrorAsync(
            try await service.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: fixture.bundleURL,
                    stagedBAMURL: staged.bamURL,
                    stagedIndexURL: staged.indexURL,
                    outputTrackID: "sam-track",
                    outputTrackName: "SAM",
                    relativeDirectory: "alignments/filtered",
                    format: .sam
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlignmentAttachmentError,
                .unsupportedFormat(.sam)
            )
        }
    }

    func testPreparedAttachmentPersistsNormalizedTrackID() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let staged = try makeStagedAlignmentArtifacts(named: "normalized-id")
        let service = PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector)

        let result = try await service.attach(
            request: PreparedAlignmentAttachmentRequest(
                bundleURL: fixture.bundleURL,
                stagedBAMURL: staged.bamURL,
                stagedIndexURL: staged.indexURL,
                outputTrackID: "  derived-track  ",
                outputTrackName: "Normalized Track ID",
                relativeDirectory: "alignments/filtered"
            )
        )

        XCTAssertEqual(result.trackInfo.id, "derived-track")
        XCTAssertEqual(result.trackInfo.sourcePath, "alignments/filtered/derived-track.bam")
        XCTAssertEqual(result.trackInfo.indexPath, "alignments/filtered/derived-track.bam.bai")
        XCTAssertEqual(result.trackInfo.metadataDBPath, "alignments/filtered/derived-track.stats.db")

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertNotNil(manifest.alignments.first(where: { $0.id == "derived-track" }))
        XCTAssertNil(manifest.alignments.first(where: { $0.id == "  derived-track  " }))
    }

    func testPreparedAttachmentRejectsSymlinkEscapeInBundleSubpath() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let service = PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector)
        let outsideDirectory = tempDir.appendingPathComponent("outside-alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)

        let alignmentsURL = fixture.bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.removeItem(at: alignmentsURL)
        try FileManager.default.createSymbolicLink(at: alignmentsURL, withDestinationURL: outsideDirectory)

        let staged = try makeStagedAlignmentArtifacts(named: "symlink-escape")

        await XCTAssertThrowsErrorAsync(
            try await service.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: fixture.bundleURL,
                    stagedBAMURL: staged.bamURL,
                    stagedIndexURL: staged.indexURL,
                    outputTrackID: "safe-track",
                    outputTrackName: "Symlink Escape",
                    relativeDirectory: "alignments/filtered"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparedAlignmentAttachmentError,
                .escapedBundlePath("alignments/filtered")
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideDirectory.appendingPathComponent("filtered/safe-track.bam").path
            )
        )
    }

    private func makeStagedAlignmentArtifacts(named name: String) throws -> (bamURL: URL, indexURL: URL) {
        let stagingURL = tempDir.appendingPathComponent("staging-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let bamURL = stagingURL.appendingPathComponent("\(name).bam")
        let indexURL = stagingURL.appendingPathComponent("\(name).bam.bai")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: indexURL.path, contents: Data("bai".utf8))
        return (bamURL, indexURL)
    }
}

private struct AlignmentFilterFixture {
    let bundleURL: URL
    let sourceBAMURL: URL
    let sourceTrackID: String
    let derivedTrackID: String
    let mappingResultURL: URL?
    let markdupPipeline: RecordingAlignmentMarkdupPipeline
    let samtoolsRunner: RecordingAlignmentSamtoolsRunner
    let metadataCollector: StubPreparedAlignmentMetadataCollector

    static func make(rootURL: URL, includeNMTag: Bool) throws -> AlignmentFilterFixture {
        let bundleURL = rootURL.appendingPathComponent("Fixture-\(UUID().uuidString).lungfishref", isDirectory: true)
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)

        let sourceBAMURL = alignmentsURL.appendingPathComponent("source.bam")
        let sourceIndexURL = alignmentsURL.appendingPathComponent("source.bam.bai")
        FileManager.default.createFile(atPath: sourceBAMURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: sourceIndexURL.path, contents: Data("bai".utf8))

        let sourceTrackID = "aln-source"
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "fixture.bundle",
            source: SourceInfo(organism: "Virus", assembly: "Fixture", database: "FixtureDB"),
            genome: nil,
            alignments: [
                AlignmentTrackInfo(
                    id: sourceTrackID,
                    name: "Fixture BAM",
                    format: .bam,
                    sourcePath: "alignments/source.bam",
                    indexPath: "alignments/source.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)

        return AlignmentFilterFixture(
            bundleURL: bundleURL,
            sourceBAMURL: sourceBAMURL,
            sourceTrackID: sourceTrackID,
            derivedTrackID: "derived-track",
            mappingResultURL: nil,
            markdupPipeline: RecordingAlignmentMarkdupPipeline(),
            samtoolsRunner: RecordingAlignmentSamtoolsRunner(requiredSAMTags: includeNMTag ? ["NM"] : []),
            metadataCollector: StubPreparedAlignmentMetadataCollector()
        )
    }

    static func makeMappingResult(
        rootURL: URL,
        includeViewerBundle: Bool,
        includeNMTag: Bool
    ) throws -> AlignmentFilterFixture {
        var fixture = try make(rootURL: rootURL, includeNMTag: includeNMTag)
        let mappingResultURL = rootURL.appendingPathComponent("mapping-result-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingResultURL, withIntermediateDirectories: true)

        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: fixture.bundleURL,
            viewerBundleURL: includeViewerBundle ? fixture.bundleURL : nil,
            bamURL: fixture.sourceBAMURL,
            baiURL: fixture.sourceBAMURL.deletingPathExtension().appendingPathExtension("bam.bai"),
            totalReads: 12,
            mappedReads: 7,
            unmappedReads: 5,
            wallClockSeconds: 1.0,
            contigs: []
        )
        try result.save(to: mappingResultURL)
        fixture = AlignmentFilterFixture(
            bundleURL: fixture.bundleURL,
            sourceBAMURL: fixture.sourceBAMURL,
            sourceTrackID: fixture.sourceTrackID,
            derivedTrackID: fixture.derivedTrackID,
            mappingResultURL: mappingResultURL,
            markdupPipeline: fixture.markdupPipeline,
            samtoolsRunner: fixture.samtoolsRunner,
            metadataCollector: fixture.metadataCollector
        )
        return fixture
    }

    func makeService() -> BundleAlignmentFilterService {
        BundleAlignmentFilterService(
            samtoolsRunner: samtoolsRunner,
            markdupPipeline: markdupPipeline,
            attachmentService: PreparedAlignmentAttachmentService(metadataCollector: metadataCollector),
            trackIDProvider: { derivedTrackID }
        )
    }
}

private actor RecordingAlignmentSamtoolsRunner: AlignmentSamtoolsRunning {
    private let requiredSAMTags: Set<String>
    private(set) var commands: [[String]] = []

    init(requiredSAMTags: Set<String>) {
        self.requiredSAMTags = requiredSAMTags
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        commands.append(arguments)

        if arguments.first == "view", arguments.contains("-c") {
            if let requiredTag = Self.requiredTag(from: arguments) {
                let count = requiredSAMTags.contains(requiredTag) ? 12 : 0
                return NativeToolResult(exitCode: 0, stdout: "\(count)\n", stderr: "")
            }
            return NativeToolResult(exitCode: 0, stdout: "12\n", stderr: "")
        }

        if let outputIndex = arguments.firstIndex(of: "-o"), outputIndex + 1 < arguments.count {
            let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
            return NativeToolResult(exitCode: 0, stdout: "", stderr: "")
        }

        if arguments.first == "index", arguments.count >= 2 {
            FileManager.default.createFile(atPath: arguments[1] + ".bai", contents: Data())
            return NativeToolResult(exitCode: 0, stdout: "", stderr: "")
        }

        return NativeToolResult(exitCode: 0, stdout: "", stderr: "")
    }

    private static func requiredTag(from arguments: [String]) -> String? {
        guard let expressionIndex = arguments.firstIndex(of: "-e"),
              expressionIndex + 1 < arguments.count else {
            return nil
        }

        let expression = arguments[expressionIndex + 1]
        guard expression.hasPrefix("exists(["),
              expression.hasSuffix("])") else {
            return nil
        }
        return String(expression.dropFirst("exists([".count).dropLast(2))
    }
}

private actor RecordingAlignmentMarkdupPipeline: AlignmentMarkdupPipelining {
    struct Invocation: Equatable {
        let inputURL: URL
        let outputURL: URL
        let removeDuplicates: Bool
        let referenceFastaPath: String?
    }

    private(set) var invocations: [Invocation] = []

    func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult {
        invocations.append(
            Invocation(
                inputURL: inputURL,
                outputURL: outputURL,
                removeDuplicates: removeDuplicates,
                referenceFastaPath: referenceFastaPath
            )
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        FileManager.default.createFile(atPath: outputURL.path + ".bai", contents: Data())

        return AlignmentMarkdupPipelineResult(
            outputURL: outputURL,
            indexURL: URL(fileURLWithPath: outputURL.path + ".bai"),
            intermediateFiles: AlignmentMarkdupIntermediateFiles(
                nameSortedBAM: outputURL.deletingLastPathComponent().appendingPathComponent("name.sorted.bam"),
                fixmateBAM: outputURL.deletingLastPathComponent().appendingPathComponent("fixmate.bam"),
                coordinateSortedBAM: outputURL.deletingLastPathComponent().appendingPathComponent("coord.sorted.bam")
            ),
            commandHistory: [
                AlignmentCommandExecutionRecord(
                    arguments: ["markdup", outputURL.path],
                    inputFile: inputURL.path,
                    outputFile: outputURL.path
                )
            ]
        )
    }
}

private struct StubPreparedAlignmentMetadataCollector: PreparedAlignmentMetadataCollecting {
    func collectMetadata(
        bamURL: URL,
        indexURL: URL,
        format: AlignmentFormat,
        referenceFastaPath: String?
    ) async throws -> PreparedAlignmentMetadataSnapshot {
        PreparedAlignmentMetadataSnapshot(
            idxstatsOutput: """
            chr1\t100\t7\t5
            *\t0\t0\t0
            """,
            flagstatOutput: """
            12 + 0 in total (QC-passed reads + QC-failed reads)
            7 + 0 mapped (58.33% : N/A)
            """,
            headerText: """
            @HD\tVN:1.6\tSO:coordinate
            @SQ\tSN:chr1\tLN:100
            @RG\tID:rg1\tSM:sample-1
            @PG\tID:samtools\tPN:samtools\tVN:1.21\tCL:samtools view
            """
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
