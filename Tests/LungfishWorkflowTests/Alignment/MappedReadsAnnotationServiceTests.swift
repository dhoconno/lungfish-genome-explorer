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

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(provenance.workflowName, "lungfish bam annotate")
        XCTAssertEqual(provenance.toolName, "lungfish bam annotate")
        XCTAssertEqual(
            provenance.durableReplayArgv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "annotate",
                "--bundle",
                fixture.bundleURL.path,
                "--alignment-track",
                fixture.sourceTrackID,
                "--output-track-name",
                "Mapped Reads",
                "--output-track-id",
                "ann-mapped",
                "--primary-only",
            ]
        )
        XCTAssertEqual(
            provenance.argv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "annotate",
                "--bundle",
                fixture.bundleURL.path,
                "--alignment-track",
                fixture.sourceTrackID,
                "--output-track-name",
                "Mapped Reads",
                "--primary-only",
            ]
        )
        XCTAssertEqual(provenance.options.explicit["sourceTrackID"]?.stringValue, fixture.sourceTrackID)
        XCTAssertEqual(provenance.options.explicit["outputTrackName"]?.stringValue, "Mapped Reads")
        XCTAssertEqual(provenance.options.defaults["primaryOnly"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["includeSequence"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["includeQualities"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["replaceExisting"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["primaryOnly"]?.booleanValue, true)
        XCTAssertEqual(provenance.options.resolvedDefaults["includeSequence"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["includeQualities"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["outputTrackID"]?.stringValue, "ann-mapped")
        XCTAssertTrue(provenance.files.contains {
            $0.path == fixture.sourceBAMURL.path
                && $0.format == .bam
                && $0.role == .input
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == databaseURL.path
                && $0.format == .sqlite
                && $0.role == .output
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let samtoolsStep = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(samtoolsStep.toolName, "samtools")
        XCTAssertEqual(samtoolsStep.toolVersion, "1.23")
        XCTAssertEqual(samtoolsStep.argv, ["samtools", "view", "-h", fixture.sourceBAMURL.path])
        XCTAssertEqual(samtoolsStep.exitStatus, 0)
        XCTAssertNotNil(samtoolsStep.wallTimeSeconds)

        let databaseSidecarURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(
            for: databaseURL,
            inBundle: fixture.bundleURL
        ))
        let databaseEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: databaseSidecarURL))
        XCTAssertEqual(databaseEnvelope.output?.path, databaseURL.path)
        XCTAssertEqual(databaseEnvelope.outputs.map(\.path), [databaseURL.path])
    }

    func testConvertMappedReadsHonorsExplicitOutputTrackID() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        read-1\t0\tchr1\t101\t60\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0
        """)
        let service = MappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "generated-id" }
        )

        let result = try await service.convertMappedReads(
            request: MappedReadsAnnotationRequest(
                bundleURL: fixture.bundleURL,
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Mapped Reads",
                outputTrackID: "mapped_reads_user"
            )
        )

        XCTAssertEqual(result.annotationTrackInfo.id, "mapped_reads_user")
        XCTAssertEqual(result.annotationTrackInfo.databasePath, "annotations/mapped_reads_user.db")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent("annotations/mapped_reads_user.db").path
        ))
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

    func testConvertMappedReadsRollsBackPublishedArtifactsWhenProvenanceFails() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let originalRootProvenance = Data("{\"workflowName\":\"existing\"}".utf8)
        let rootProvenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try originalRootProvenance.write(to: rootProvenanceURL)
        let existingSidecarURL = fixture.bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("existing.lungfish-provenance.json")
        try FileManager.default.createDirectory(
            at: existingSidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing sidecar".utf8).write(to: existingSidecarURL)

        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        read-1\t0\tchr1\t101\t60\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0
        """)
        let service = MappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-rollback" },
            provenancePublisher: { _ in throw InjectedProvenanceError.failed }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.convertMappedReads(
                request: MappedReadsAnnotationRequest(
                    bundleURL: fixture.bundleURL,
                    sourceTrackID: fixture.sourceTrackID,
                    outputTrackName: "Rollback"
                )
            )
        ) { error in
            XCTAssertEqual(error as? InjectedProvenanceError, .failed)
        }

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent("annotations/ann-rollback.db").path
        ))
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), originalRootProvenance)
        XCTAssertEqual(try Data(contentsOf: existingSidecarURL), Data("existing sidecar".utf8))
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
        let staleSourceProvenanceURL = fixture.bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("alignments", isDirectory: true)
            .appendingPathComponent("source.bam.lungfish-provenance.json")
        try FileManager.default.createDirectory(
            at: staleSourceProvenanceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale copied source provenance".utf8).write(to: staleSourceProvenanceURL)
        let staleRootProvenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try Data("{\"workflowName\":\"stale\"}".utf8).write(to: staleRootProvenanceURL)
        let staleRootSignatureURL = ProvenanceSigningConfiguration.signatureURL(for: staleRootProvenanceURL)
        let staleRootPublicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: staleRootProvenanceURL)
        try Data("stale signature".utf8).write(to: staleRootSignatureURL)
        try Data("stale public key".utf8).write(to: staleRootPublicKeyURL)
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
                outputTrackID: "miseq_mhc_user",
                primaryOnly: true
            )
        )

        XCTAssertEqual(result.outputBundleURL, outputBundleURL)
        XCTAssertEqual(result.annotationTrackInfo.id, "miseq_mhc_user")
        XCTAssertEqual(result.convertedRecordCount, 2)
        XCTAssertEqual(result.selectedRecordCount, 2)
        XCTAssertEqual(result.candidateRecordCount, 3)
        XCTAssertEqual(result.skippedSecondarySupplementaryCount, 1)

        let sourceManifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(sourceManifest.annotations.isEmpty)
        let manifest = try BundleManifest.load(from: outputBundleURL)
        XCTAssertEqual(manifest.annotations.first?.name, "miSeq MHC")

        let database = try AnnotationDatabase(
            url: outputBundleURL.appendingPathComponent("annotations/miseq_mhc_user.db")
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

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputBundleURL))
        XCTAssertEqual(provenance.workflowName, "lungfish bam annotate-best")
        XCTAssertEqual(
            provenance.argv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "annotate-best",
                "--bundle",
                fixture.bundleURL.path,
                "--mapping-result",
                mappingDirectory.path,
                "--output-bundle",
                outputBundleURL.path,
                "--output-track-name",
                "miSeq MHC",
                "--output-track-id",
                "miseq_mhc_user",
                "--primary-only",
            ]
        )
        XCTAssertEqual(provenance.options.defaults["primaryOnly"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["replaceExisting"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["primaryOnly"]?.booleanValue, true)
        XCTAssertEqual(provenance.options.resolvedDefaults["outputTrackID"]?.stringValue, "miseq_mhc_user")
        XCTAssertEqual(
            provenance.options.resolvedDefaults["selectionStrategy"]?.stringValue,
            "best_overlapping_interval_by_nm"
        )
        XCTAssertTrue(provenance.files.contains {
            $0.path == bamURL.path
                && $0.format == .bam
                && $0.role == .input
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let databaseURL = outputBundleURL.appendingPathComponent("annotations/miseq_mhc_user.db")
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == databaseURL.path
                && $0.format == .sqlite
                && $0.role == .output
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let databaseSidecarURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(
            for: databaseURL,
            inBundle: outputBundleURL
        ))
        let databaseEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: databaseSidecarURL))
        XCTAssertEqual(databaseEnvelope.output?.path, databaseURL.path)
        XCTAssertEqual(databaseEnvelope.outputs.map(\.path), [databaseURL.path])
        let inheritedStaleSidecar = outputBundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("alignments", isDirectory: true)
            .appendingPathComponent("source.bam.lungfish-provenance.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inheritedStaleSidecar.path))
        let inheritedRootSignatureURL = ProvenanceSigningConfiguration.signatureURL(
            for: outputBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        )
        let inheritedRootPublicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(
            for: outputBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: inheritedRootSignatureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inheritedRootPublicKeyURL.path))
    }

    func testConvertBestMappedReadsDoesNotTransitivelyMergeNonOverlappingReadsAcrossBridge() async throws {
        // Regression for F34: read A (100-200) and read C (480-520) never overlap each
        // other, but read B (150-500) overlaps both. A naive cluster that only compares
        // incoming records against the cluster's ever-growing span (rather than each
        // record's real overlap) would bridge A and C into one cluster via B. They must
        // land in two clusters: {A, B} and {C}.
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let mappingDirectory = tempDir.appendingPathComponent("bridge-mapping", isDirectory: true)
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
            totalReads: 3,
            mappedReads: 3,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: mappingDirectory)

        // read-A: 0-based [100, 200)
        // read-B: 0-based [150, 500) -- overlaps both A and C
        // read-C: 0-based [480, 520) -- does NOT overlap read-A ([100,200) vs [480,520))
        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:1000
        read-A\t0\tchr1\t101\t60\t100M\t*\t0\t0\t\(String(repeating: "A", count: 100))\t\(String(repeating: "I", count: 100))\tNM:i:1
        read-B\t0\tchr1\t151\t60\t350M\t*\t0\t0\t\(String(repeating: "C", count: 350))\t\(String(repeating: "I", count: 350))\tNM:i:5
        read-C\t0\tchr1\t481\t60\t40M\t*\t0\t0\t\(String(repeating: "G", count: 40))\t\(String(repeating: "I", count: 40))\tNM:i:1
        """)
        let service = BestMappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-bridge" }
        )
        let outputBundleURL = tempDir.appendingPathComponent("BestMappedReadsBridge.lungfishref", isDirectory: true)

        let result = try await service.convertBestMappedReads(
            request: BestMappedReadsAnnotationRequest(
                sourceBundleURL: fixture.bundleURL,
                mappingResultURL: mappingDirectory,
                outputBundleURL: outputBundleURL,
                outputTrackName: "miSeq MHC",
                outputTrackID: "miseq_mhc_bridge",
                primaryOnly: true
            )
        )

        // Two distinct genomic intervals must survive: {read-A, read-B} and {read-C}.
        XCTAssertEqual(result.selectedRecordCount, 2)

        let database = try AnnotationDatabase(
            url: outputBundleURL.appendingPathComponent("annotations/miseq_mhc_bridge.db")
        )
        let records = database.queryByRegion(chromosome: "chr1", start: 0, end: 600)
        XCTAssertEqual(records.map(\.name).sorted(), ["read-A", "read-C"])

        let clusterA = try XCTUnwrap(records.first { $0.name == "read-A" })
        let clusterAAttributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(clusterA.attributes))
        // read-A won its cluster over read-B (NM 1 < 5); the cluster must contain
        // exactly {A, B}, not {A, B, C}.
        XCTAssertEqual(clusterAAttributes["best_interval_candidate_count"], "2")
        XCTAssertEqual(clusterAAttributes["best_interval_start"], "100")
        XCTAssertEqual(clusterAAttributes["best_interval_end"], "500")

        let clusterC = try XCTUnwrap(records.first { $0.name == "read-C" })
        let clusterCAttributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(clusterC.attributes))
        XCTAssertEqual(clusterCAttributes["best_interval_candidate_count"], "1")
        XCTAssertEqual(clusterCAttributes["best_interval_start"], "480")
        XCTAssertEqual(clusterCAttributes["best_interval_end"], "520")
    }

    func testConvertBestMappedReadsRemovesCopiedOutputBundleWhenProvenanceFails() async throws {
        let fixture = try MappedReadsAnnotationFixture.make(rootURL: tempDir)
        let mappingDirectory = tempDir.appendingPathComponent("rollback-mapping", isDirectory: true)
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
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1.0,
            contigs: []
        ).save(to: mappingDirectory)

        let runner = RecordingMappedReadsSamtoolsRunner(stdout: """
        read-1\t0\tchr1\t101\t60\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0
        """)
        let service = BestMappedReadsAnnotationService(
            samtoolsRunner: runner,
            trackIDProvider: { _ in "ann-best-rollback" },
            provenancePublisher: { _ in throw InjectedProvenanceError.failed }
        )
        let outputBundleURL = tempDir.appendingPathComponent("RollbackBest.lungfishref", isDirectory: true)

        await XCTAssertThrowsErrorAsync(
            try await service.convertBestMappedReads(
                request: BestMappedReadsAnnotationRequest(
                    sourceBundleURL: fixture.bundleURL,
                    mappingResultURL: mappingDirectory,
                    outputBundleURL: outputBundleURL,
                    outputTrackName: "Rollback Best"
                )
            )
        ) { error in
            XCTAssertEqual(error as? InjectedProvenanceError, .failed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputBundleURL.path))
        let sourceManifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(sourceManifest.annotations.isEmpty)
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
                outputTrackID: "ipd_cds_user",
                minimumQueryCoverage: 0.95
            )
        )

        XCTAssertEqual(result.geneCount, 2)
        XCTAssertEqual(result.cdsCount, 4)
        XCTAssertEqual(result.candidateRecordCount, 3)
        XCTAssertEqual(result.selectedLocusCount, 2)

        let manifest = try BundleManifest.load(from: outputBundleURL)
        XCTAssertEqual(manifest.annotations.first?.name, "IPD CDS best")
        XCTAssertEqual(manifest.annotations.first?.id, "ipd_cds_user")
        let database = try AnnotationDatabase(
            url: outputBundleURL.appendingPathComponent("annotations/ipd_cds_user.db")
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

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputBundleURL))
        XCTAssertEqual(provenance.workflowName, "lungfish bam annotate-cds-best")
        XCTAssertEqual(
            provenance.argv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "annotate-cds-best",
                "--bundle",
                fixture.bundleURL.path,
                "--mapping-result",
                mappingDirectory.path,
                "--output-bundle",
                outputBundleURL.path,
                "--output-track-name",
                "IPD CDS best",
                "--output-track-id",
                "ipd_cds_user",
                "--min-query-cover",
                "0.95",
            ]
        )
        XCTAssertEqual(provenance.options.defaults["includeSecondary"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["includeSupplementary"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["minimumQueryCoverage"]?.numberValue, 0.5)
        XCTAssertEqual(provenance.options.defaults["replaceExisting"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["minimumQueryCoverage"]?.numberValue, 0.95)
        XCTAssertEqual(provenance.options.resolvedDefaults["outputTrackID"]?.stringValue, "ipd_cds_user")
        XCTAssertEqual(
            provenance.options.resolvedDefaults["selectionStrategy"]?.stringValue,
            "best_cds_model_by_nm_and_query_coverage"
        )
        XCTAssertTrue(provenance.files.contains {
            $0.path == bamURL.path
                && $0.format == .bam
                && $0.role == .input
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let databaseURL = outputBundleURL.appendingPathComponent("annotations/ipd_cds_user.db")
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == databaseURL.path
                && $0.format == .sqlite
                && $0.role == .output
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        let databaseSidecarURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(
            for: databaseURL,
            inBundle: outputBundleURL
        ))
        let databaseEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: databaseSidecarURL))
        XCTAssertEqual(databaseEnvelope.output?.path, databaseURL.path)
        XCTAssertEqual(databaseEnvelope.outputs.map(\.path), [databaseURL.path])
    }

    func testCDSBestDefaultsExcludeSecondaryAndSupplementaryAlignments() {
        let request = CDSBestAnnotationRequest(
            sourceBundleURL: URL(fileURLWithPath: "/tmp/source.lungfishref"),
            mappingResultURL: URL(fileURLWithPath: "/tmp/mapping"),
            outputBundleURL: URL(fileURLWithPath: "/tmp/output.lungfishref"),
            outputTrackName: "CDS"
        )

        XCTAssertFalse(request.includeSecondary)
        XCTAssertFalse(request.includeSupplementary)
        XCTAssertEqual(request.minimumQueryCoverage, 0.5)
    }

}

private enum InjectedProvenanceError: Error, Equatable {
    case failed
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
    private let version: String
    private(set) var commands: [[String]] = []

    init(stdout: String, version: String = "1.23") {
        self.stdout = stdout
        self.version = version
    }

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        commands.append(arguments)
        return NativeToolResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    func samtoolsVersion() async -> String {
        version
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
