import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class MappedReadsAnnotationServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedReadsAnnotationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testConvertMappedReadsCreatesAnnotationTrackAndDatabase() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:1000
        primary-1\t0\tchr1\t101\t60\t20M\t*\t0\t0\tAAAAAAAAAAAAAAAAAAAA\tIIIIIIIIIIIIIIIIIIII\tNM:i:0\tAS:i:20
        unmapped-1\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*
        secondary-1\t256\tchr1\t151\t30\t10M\t*\t0\t0\tCCCCCCCCCC\tJJJJJJJJJJ\tNM:i:1
        """)
        let service = MappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-mapped" }
        )

        let result = try await service.convertMappedReads(
            request: MappedReadsAnnotationRequest(
                bundleURL: fixture.bundleURL,
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads",
                primaryOnly: true
            )
        )

        XCTAssertEqual(result.bundleURL, fixture.bundleURL)
        XCTAssertEqual(result.sourceAlignmentTrackID, fixture.sourceTrackID)
        XCTAssertEqual(result.sourceAlignmentTrackName, fixture.sourceTrackName)
        XCTAssertEqual(result.annotationTrackInfo.id, "ann-mapped")
        XCTAssertEqual(result.annotationTrackInfo.name, "Mapped Reads")
        XCTAssertEqual(result.annotationTrackInfo.databasePath, "annotations/ann-mapped.db")
        XCTAssertEqual(result.annotationTrackInfo.featureCount, 1)
        XCTAssertEqual(result.convertedRecordCount, 1)
        XCTAssertEqual(result.skippedUnmappedCount, 1)
        XCTAssertEqual(result.skippedSecondarySupplementaryCount, 1)
        XCTAssertFalse(result.includedSequence)
        XCTAssertFalse(result.includedQualities)

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        let track = try XCTUnwrap(manifest.annotations.first { $0.id == "ann-mapped" })
        XCTAssertEqual(track.annotationType, .custom)
        XCTAssertEqual(track.databasePath, "annotations/ann-mapped.db")

        let databaseURL = fixture.bundleURL.appendingPathComponent("annotations/ann-mapped.db")
        let database = try AnnotationDatabase(url: databaseURL)
        let record = try XCTUnwrap(database.queryByRegion(chromosome: "chr1", start: 100, end: 121).first)
        let attributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(record.attributes))
        XCTAssertEqual(record.name, "primary-1")
        XCTAssertEqual(attributes["mapq"], "60")
        XCTAssertEqual(attributes["tag_NM"], "0")
        XCTAssertEqual(attributes["tag_AS"], "20")
        XCTAssertNil(attributes["sequence"])
        XCTAssertNil(attributes["qualities"])

        let commands = await runner.commands
        XCTAssertEqual(commands, [["view", "-h", fixture.sourceBAMURL.path]])
    }

    func testConvertMappedReadsIncludesSequenceAndQualitiesWhenRequested() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        read-1\t0\tchr1\t101\t60\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0
        """)
        let service = MappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-seq" }
        )

        _ = try await service.convertMappedReads(
            request: MappedReadsAnnotationRequest(
                bundleURL: fixture.bundleURL,
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads With Bases",
                includeSequence: true,
                includeQualities: true
            )
        )

        let database = try AnnotationDatabase(
            url: fixture.bundleURL.appendingPathComponent("annotations/ann-seq.db")
        )
        let record = try XCTUnwrap(database.queryByRegion(chromosome: "chr1", start: 100, end: 104).first)
        let attributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(record.attributes))
        XCTAssertEqual(attributes["sequence"], "ACGT")
        XCTAssertEqual(attributes["qualities"], "ABCD")
    }

    func testConvertMappedReadsRejectsExistingOutputUnlessReplacing() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let existingTrack = AnnotationTrackInfo(
            id: "ann-mapped",
            name: "Mapped Reads",
            path: "annotations/ann-mapped.db",
            databasePath: "annotations/ann-mapped.db",
            annotationType: .custom,
            featureCount: 1
        )
        try BundleManifest.load(from: fixture.bundleURL)
            .addingAnnotationTrack(existingTrack)
            .save(to: fixture.bundleURL)
        FileManager.default.createFile(
            atPath: fixture.bundleURL.appendingPathComponent("annotations/ann-mapped.db").path,
            contents: Data("old".utf8)
        )

        let runner = RecordingMappedReadsSamtoolsRunner(stdout: "read-1\t0\tchr1\t101\t60\t4M\t*\t0\t0\tACGT\tABCD\n")
        let service = MappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-mapped" }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.convertMappedReads(
                request: MappedReadsAnnotationRequest(
                    bundleURL: fixture.bundleURL,
                    sourceTrackID: fixture.sourceTrackID,
                    outputTrackName: "Mapped Reads"
                )
            )
        ) { error in
            XCTAssertEqual(error as? MappedReadsAnnotationServiceError, .outputTrackExists("Mapped Reads"))
        }

        let result = try await service.convertMappedReads(
            request: MappedReadsAnnotationRequest(
                bundleURL: fixture.bundleURL,
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads",
                replaceExisting: true
            )
        )

        XCTAssertEqual(result.convertedRecordCount, 1)
        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.annotations.filter { $0.id == "ann-mapped" }.count, 1)
    }

    func testConvertBestMappedReadsKeepsLowestNMPerOverlappingIntervalInCopiedBundle() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let mappingDirectory = tempDir.appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDirectory, withIntermediateDirectories: true)
        let bamURL = mappingDirectory.appendingPathComponent("miseq.sorted.bam")
        let baiURL = mappingDirectory.appendingPathComponent("miseq.sorted.bam.bai")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: baiURL.path, contents: Data("bai".utf8))
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 4,
            mappedReads: 4,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: mappingDirectory)

        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:1000
        worse-overlap\t0\tchr1\t101\t60\t20M\t*\t0\t0\tAAAAAAAAAAAAAAAAAAAA\tIIIIIIIIIIIIIIIIIIII\tNM:i:4
        best-overlap\t0\tchr1\t105\t55\t20M\t*\t0\t0\tCCCCCCCCCCCCCCCCCCCC\tIIIIIIIIIIIIIIIIIIII\tNM:i:1
        next-interval\t0\tchr1\t201\t60\t20M\t*\t0\t0\tGGGGGGGGGGGGGGGGGGGG\tIIIIIIIIIIIIIIIIIIII\tNM:i:2
        secondary-skip\t256\tchr1\t205\t60\t20M\t*\t0\t0\tTTTTTTTTTTTTTTTTTTTT\tIIIIIIIIIIIIIIIIIIII\tNM:i:0
        """)
        let service = BestMappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-best" }
        )
        let outputBundleURL = tempDir.appendingPathComponent("BestMappedReads.lungfishref", isDirectory: true)

        let result = try await service.convertBestMappedReads(
            request: BestMappedReadsAnnotationRequest(
                sourceBundleURL: fixture.bundleURL,
                mappingResultURL: mappingDirectory,
                outputBundleURL: outputBundleURL,
                outputTrackName: "miSeq MHC",
                primaryOnly: true
            )
        )

        XCTAssertEqual(result.outputBundleURL, outputBundleURL)
        XCTAssertEqual(result.annotationTrackInfo.id, "ann-best")
        XCTAssertEqual(result.convertedRecordCount, 2)
        XCTAssertEqual(result.selectedRecordCount, 2)
        XCTAssertEqual(result.candidateRecordCount, 3)
        XCTAssertEqual(result.skippedSecondarySupplementaryCount, 1)

        let sourceManifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(sourceManifest.annotations.isEmpty)
        let manifest = try BundleManifest.load(from: outputBundleURL)
        XCTAssertEqual(manifest.annotations.first?.name, "miSeq MHC")

        let database = try AnnotationDatabase(
            url: outputBundleURL.appendingPathComponent("annotations/ann-best.db")
        )
        let records = database.queryByRegion(chromosome: "chr1", start: 0, end: 300)
        XCTAssertEqual(records.map(\.name).sorted(), ["best-overlap", "next-interval"])
        let best = try XCTUnwrap(records.first { $0.name == "best-overlap" })
        let bestAttributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(best.attributes))
        XCTAssertEqual(bestAttributes["tag_NM"], "1")
        XCTAssertEqual(bestAttributes["best_interval_start"], "100")
        XCTAssertEqual(bestAttributes["best_interval_end"], "124")
        XCTAssertEqual(bestAttributes["best_interval_candidate_count"], "2")

        let commands = await runner.commands
        XCTAssertEqual(commands, [["view", "-h", bamURL.path]])
    }

    func testConvertBestCDSCreatesGeneAndCDSRowsFromSplicedModels() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let mappingDirectory = tempDir.appendingPathComponent("cds-mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDirectory, withIntermediateDirectories: true)
        let bamURL = mappingDirectory.appendingPathComponent("cds.sorted.bam")
        let baiURL = mappingDirectory.appendingPathComponent("cds.sorted.bam.bai")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: baiURL.path, contents: Data("bai".utf8))
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.minimap2Splice.id,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 4,
            mappedReads: 4,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: mappingDirectory)

        let sequence100 = String(repeating: "A", count: 100)
        let quality100 = String(repeating: "I", count: 100)
        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:1000
        worse-allele\t0\tchr1\t101\t60\t50M100N50M\t*\t0\t0\t\(sequence100)\t\(quality100)\tNM:i:5
        best-allele\t0\tchr1\t105\t55\t50M100N50M\t*\t0\t0\t\(sequence100)\t\(quality100)\tNM:i:1
        next-locus\t16\tchr1\t501\t60\t30M40N70M\t*\t0\t0\t\(sequence100)\t\(quality100)\tNM:i:2
        Mafa-A1*001:01\t0\tchr1\t101\t60\t50M200000N50M\t*\t0\t0\t\(sequence100)\t\(quality100)\tNM:i:0
        partial-skip\t0\tchr1\t701\t60\t40M60S\t*\t0\t0\t\(String(repeating: "C", count: 100))\t\(String(repeating: "I", count: 100))\tNM:i:0
        """)
        let service = CDSBestAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-cds-best" }
        )
        let outputBundleURL = tempDir.appendingPathComponent("CDSBest.lungfishref", isDirectory: true)

        let result = try await service.convertBestCDS(
            request: CDSBestAnnotationRequest(
                sourceBundleURL: fixture.bundleURL,
                mappingResultURL: mappingDirectory,
                outputBundleURL: outputBundleURL,
                outputTrackName: "IPD CDS best",
                minimumQueryCoverage: 0.95
            )
        )

        XCTAssertEqual(result.geneCount, 2)
        XCTAssertEqual(result.cdsCount, 4)
        XCTAssertEqual(result.candidateRecordCount, 3)
        XCTAssertEqual(result.selectedLocusCount, 2)

        let manifest = try BundleManifest.load(from: outputBundleURL)
        XCTAssertEqual(manifest.annotations.first?.name, "IPD CDS best")
        let database = try AnnotationDatabase(
            url: outputBundleURL.appendingPathComponent("annotations/ann-cds-best.db")
        )
        let records = database.queryByRegion(chromosome: "chr1", start: 0, end: 900, limit: 100)
        XCTAssertEqual(records.filter { $0.type == "gene" }.compactMap(\.geneName).sorted(), ["best-allele", "next-locus"])
        XCTAssertEqual(records.filter { $0.type == "CDS" }.count, 4)

        let bestGene = try XCTUnwrap(records.first { $0.type == "gene" && $0.geneName == "best-allele" })
        XCTAssertEqual(bestGene.start, 104)
        XCTAssertEqual(bestGene.end, 304)
        let attributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(bestGene.attributes))
        XCTAssertEqual(attributes["nm"], "1")
        XCTAssertEqual(attributes["cds_component_count"], "2")

        let commands = await runner.commands
        XCTAssertEqual(commands, [["view", "-h", bamURL.path]])
    }

}

private struct MappedReadsAnnotationFixture {
    let bundleURL: URL
    let sourceTrackID: String
    let sourceTrackName: String
    let sourceBAMURL: URL

    static func make(rootURL: URL) throws -> MappedReadsAnnotationFixture {
        let bundleURL = rootURL.appendingPathComponent("MappedReadsFixture-\(UUID().uuidString).lungfishref", isDirectory: true)
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let annotationsURL = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)

        let sourceBAMURL = alignmentsURL.appendingPathComponent("source.bam")
        let sourceBAIURL = alignmentsURL.appendingPathComponent("source.bam.bai")
        FileManager.default.createFile(atPath: sourceBAMURL.path, contents: Data("bam".utf8))
        FileManager.default.createFile(atPath: sourceBAIURL.path, contents: Data("bai".utf8))

        let sourceTrackID = "aln-source"
        let sourceTrackName = "Source BAM"
        let manifest = BundleManifest(
            name: "Mapped Reads Fixture",
            identifier: "mapped-reads-fixture.\(UUID().uuidString)",
            source: SourceInfo(
                organism: "Fixture organism",
                assembly: "Fixture assembly",
                database: "Fixture database"
            ),
            genome: nil,
            alignments: [
                AlignmentTrackInfo(
                    id: sourceTrackID,
                    name: sourceTrackName,
                    format: .bam,
                    sourcePath: "alignments/source.bam",
                    indexPath: "alignments/source.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)

        return MappedReadsAnnotationFixture(
            bundleURL: bundleURL,
            sourceTrackID: sourceTrackID,
            sourceTrackName: sourceTrackName,
            sourceBAMURL: sourceBAMURL
        )
    }
}

private actor RecordingMappedReadsSamtoolsRunner: AlignmentSamtoolsRunning {
    private let stdout: String
    private(set) var commands: [[String]] = []

    init(stdout: String) {
        self.stdout = stdout
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        commands.append(arguments)
        return NativeToolResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verification: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verification(error)
    }
}
