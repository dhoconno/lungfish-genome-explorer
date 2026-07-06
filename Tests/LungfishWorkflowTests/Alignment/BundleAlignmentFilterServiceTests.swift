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
        XCTAssertEqual(db.getFileInfo("derivation_filter_summary"), "Exact matches; mapped reads only")
        XCTAssertEqual(db.getFileInfo("derivation_identity_filter"), "exact_match")
        XCTAssertEqual(db.getFileInfo("derivation_mapped_only"), "true")
        XCTAssertEqual(db.getFileInfo("derivation_primary_only"), "false")
        XCTAssertEqual(db.getFileInfo("derivation_target_kind"), "bundle")
        XCTAssertEqual(db.getFileInfo("mapped_reads"), "7")
        XCTAssertEqual(db.getFileInfo("unmapped_reads"), "5")
        XCTAssertEqual(db.sampleNames(), ["sample-1"])
        XCTAssertEqual(db.provenanceHistory().map(\.subcommand), ["view", "sort", "index"])

        let bamURL = fixture.bundleURL.appendingPathComponent(result.trackInfo.sourcePath)
        let indexURL = fixture.bundleURL.appendingPathComponent(result.trackInfo.indexPath)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(provenance.workflowName, "lungfish bam filter")
        XCTAssertEqual(
            provenance.argv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "filter",
                "--bundle",
                fixture.bundleURL.path,
                "--alignment-track",
                fixture.sourceTrackID,
                "--output-track-name",
                "Exact Match Reads",
                "--mapped-only",
                "--exact-match",
            ]
        )
        XCTAssertEqual(
            provenance.durableReplayArgv,
            [
                CLICommandIdentity.executableName,
                "bam",
                "filter",
                "--bundle",
                fixture.bundleURL.path,
                "--alignment-track",
                fixture.sourceTrackID,
                "--output-track-id",
                fixture.derivedTrackID,
                "--output-track-name",
                "Exact Match Reads",
                "--mapped-only",
                "--exact-match",
            ]
        )
        XCTAssertEqual(provenance.options.explicit["targetKind"]?.stringValue, "bundle")
        XCTAssertEqual(provenance.options.explicit["sourceTrackID"]?.stringValue, fixture.sourceTrackID)
        XCTAssertEqual(provenance.options.explicit["outputTrackName"]?.stringValue, "Exact Match Reads")
        XCTAssertNil(provenance.options.explicit["outputTrackID"])
        XCTAssertEqual(provenance.options.defaults["outputTrackID"], .null)
        XCTAssertEqual(provenance.options.defaults["mappedOnly"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["primaryOnly"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.defaults["duplicateMode"]?.stringValue, "none")
        XCTAssertEqual(provenance.options.defaults["identityFilter"]?.stringValue, "none")
        XCTAssertEqual(provenance.options.resolvedDefaults["mappedOnly"]?.booleanValue, true)
        XCTAssertEqual(provenance.options.resolvedDefaults["primaryOnly"]?.booleanValue, false)
        XCTAssertEqual(provenance.options.resolvedDefaults["identityFilter"]?.stringValue, "exact_match")
        XCTAssertEqual(provenance.options.resolvedDefaults["outputTrackID"]?.stringValue, fixture.derivedTrackID)
        XCTAssertTrue(provenance.files.contains {
            $0.path == fixture.sourceBAMURL.path
                && $0.format == .bam
                && $0.role == .input
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.files.contains {
            $0.path == fixture.referenceFASTAURL.path
                && $0.format == .fasta
                && $0.role == .reference
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })
        for outputURL in [bamURL, indexURL, metadataURL] {
            XCTAssertTrue(provenance.outputs.contains {
                $0.path == outputURL.path
                    && $0.role == .output
                    && $0.checksumSHA256 != nil
                    && $0.fileSize != nil
            })
        }
        XCTAssertEqual(provenance.steps.map(\.toolName), ["samtools", "samtools", "samtools", "lungfish bam filter"])
        XCTAssertEqual(provenance.steps.first?.argv, ["samtools"] + result.commandHistory[0].arguments)
        XCTAssertEqual(provenance.steps.first?.toolVersion, "1.23")
        XCTAssertEqual(provenance.steps.first?.exitStatus, 0)
        XCTAssertNotNil(provenance.steps.first?.wallTimeSeconds)
        XCTAssertNotNil(provenance.steps.first?.startedAt)
        XCTAssertNotNil(provenance.steps.first?.completedAt)
        for (step, command) in zip(provenance.steps.prefix(result.commandHistory.count), result.commandHistory) {
            let inputFile = try XCTUnwrap(command.inputFile)
            let outputFile = try XCTUnwrap(command.outputFile)
            XCTAssertTrue(step.inputs.contains {
                $0.path == inputFile
                    && $0.role == .input
                    && $0.checksumSHA256 != nil
                    && $0.fileSize != nil
            })
            XCTAssertTrue(step.outputs.contains {
                $0.path == outputFile
                    && $0.role == .output
                    && $0.checksumSHA256 != nil
                    && $0.fileSize != nil
            })
        }
        let sortStep = try XCTUnwrap(provenance.steps.first { $0.argv.dropFirst().first == "sort" })
        XCTAssertTrue(sortStep.inputs.contains {
            $0.path == fixture.referenceFASTAURL.path
                && $0.role == .reference
                && $0.checksumSHA256 != nil
        })

        let bamSidecarURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(
            for: bamURL,
            inBundle: fixture.bundleURL
        ))
        let bamEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: bamSidecarURL))
        XCTAssertEqual(bamEnvelope.output?.path, bamURL.path)
        XCTAssertEqual(bamEnvelope.outputs.map(\.path), [bamURL.path])
        let provenancePaths = try bundleProvenanceRelativePaths(in: fixture.bundleURL)
        XCTAssertFalse(provenancePaths.contains { $0.contains(".filter-") })
    }

    func testBundleTargetRecordsExplicitOutputTrackIDInExactArgv() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let service = fixture.makeService()

        let result = try await service.deriveFilteredAlignment(
            target: .bundle(fixture.bundleURL),
            sourceTrackID: fixture.sourceTrackID,
            outputTrackName: "User ID Reads",
            outputTrackID: "user-filtered",
            filterRequest: AlignmentFilterRequest(mappedOnly: true)
        )

        XCTAssertEqual(result.trackInfo.id, "user-filtered")
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(provenance.options.explicit["outputTrackID"]?.stringValue, "user-filtered")
        XCTAssertEqual(provenance.options.resolvedDefaults["outputTrackID"]?.stringValue, "user-filtered")
        XCTAssertEqual(provenance.argv, provenance.durableReplayArgv)
        XCTAssertTrue(provenance.argv.contains("--output-track-id"))
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

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertNil(provenance.options.explicit["bundlePath"])
        XCTAssertEqual(provenance.options.explicit["mappingResultPath"]?.fileValue?.path, fixture.mappingResultURL?.path)
        XCTAssertEqual(provenance.options.resolvedDefaults["bundlePath"]?.fileValue?.path, fixture.bundleURL.path)
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
        XCTAssertEqual(db.getFileInfo("derivation_filter_summary"), "99% minimum identity; duplicate-marked reads removed")
        XCTAssertEqual(db.getFileInfo("derivation_identity_filter"), "minimum_percent_identity:99")
        XCTAssertEqual(
            db.getFileInfo("derivation_preprocessing"),
            "samtools markdup(removeDuplicates=false)"
        )
        XCTAssertEqual(db.provenanceHistory().first?.subcommand, "markdup")
    }

    func testDerivedFilterRollsBackAttachedArtifactsWhenProvenanceFails() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let originalRootProvenance = Data("{\"workflowName\":\"existing\"}".utf8)
        let rootProvenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try originalRootProvenance.write(to: rootProvenanceURL)

        let service = BundleAlignmentFilterService(
            samtoolsRunner: fixture.samtoolsRunner,
            markdupPipeline: fixture.markdupPipeline,
            attachmentService: PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector),
            trackIDProvider: { fixture.derivedTrackID },
            provenancePublisher: { _ in throw InjectedFilterProvenanceError.failed }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.deriveFilteredAlignment(
                target: .bundle(fixture.bundleURL),
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Rollback Filter",
                filterRequest: AlignmentFilterRequest(mappedOnly: true)
            )
        ) { error in
            XCTAssertEqual(error as? InjectedFilterProvenanceError, .failed)
        }

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertNil(manifest.alignments.first(where: { $0.id == fixture.derivedTrackID }))
        XCTAssertNotNil(manifest.alignments.first(where: { $0.id == fixture.sourceTrackID }))
        for relativePath in [
            "alignments/filtered/\(fixture.derivedTrackID).bam",
            "alignments/filtered/\(fixture.derivedTrackID).bam.bai",
            "alignments/filtered/\(fixture.derivedTrackID).stats.db",
        ] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.bundleURL.appendingPathComponent(relativePath).path
            ))
        }
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), originalRootProvenance)
    }

    func testDerivedFilterRollsBackNormalizedExplicitTrackIDWhenProvenanceFails() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let service = BundleAlignmentFilterService(
            samtoolsRunner: fixture.samtoolsRunner,
            markdupPipeline: fixture.markdupPipeline,
            attachmentService: PreparedAlignmentAttachmentService(metadataCollector: fixture.metadataCollector),
            trackIDProvider: { "unused-generated-id" },
            provenancePublisher: { _ in throw InjectedFilterProvenanceError.failed }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.deriveFilteredAlignment(
                target: .bundle(fixture.bundleURL),
                sourceTrackID: fixture.sourceTrackID,
                outputTrackName: "Rollback Filter",
                outputTrackID: "  derived-track  ",
                filterRequest: AlignmentFilterRequest(mappedOnly: true)
            )
        ) { error in
            XCTAssertEqual(error as? InjectedFilterProvenanceError, .failed)
        }

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertNil(manifest.alignments.first(where: { $0.id == fixture.derivedTrackID }))
        for relativePath in [
            "alignments/filtered/\(fixture.derivedTrackID).bam",
            "alignments/filtered/\(fixture.derivedTrackID).bam.bai",
            "alignments/filtered/\(fixture.derivedTrackID).stats.db",
        ] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.bundleURL.appendingPathComponent(relativePath).path
            ))
        }
    }

    func testRemovalServiceDeletesDerivedTrackArtifactsAndUpdatesManifest() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)
        let filteredDirectory = fixture.bundleURL.appendingPathComponent("alignments/filtered", isDirectory: true)
        try FileManager.default.createDirectory(at: filteredDirectory, withIntermediateDirectories: true)

        let derivedTrack = AlignmentTrackInfo(
            id: fixture.derivedTrackID,
            name: "Exact matches",
            format: .bam,
            sourcePath: "alignments/filtered/\(fixture.derivedTrackID).bam",
            indexPath: "alignments/filtered/\(fixture.derivedTrackID).bam.bai",
            metadataDBPath: "alignments/filtered/\(fixture.derivedTrackID).stats.db"
        )
        FileManager.default.createFile(
            atPath: fixture.bundleURL.appendingPathComponent(derivedTrack.sourcePath).path,
            contents: Data("bam".utf8)
        )
        FileManager.default.createFile(
            atPath: fixture.bundleURL.appendingPathComponent(derivedTrack.indexPath).path,
            contents: Data("bai".utf8)
        )
        FileManager.default.createFile(
            atPath: fixture.bundleURL.appendingPathComponent(try XCTUnwrap(derivedTrack.metadataDBPath)).path,
            contents: Data("db".utf8)
        )
        try BundleManifest.load(from: fixture.bundleURL)
            .addingAlignmentTrack(derivedTrack)
            .save(to: fixture.bundleURL)

        let result = try await BundleAlignmentTrackRemovalService().removeDerivedAlignmentTrack(
            bundleURL: fixture.bundleURL,
            trackID: fixture.derivedTrackID
        )

        XCTAssertEqual(result.removedTrack.id, fixture.derivedTrackID)
        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertNil(manifest.alignments.first(where: { $0.id == fixture.derivedTrackID }))
        XCTAssertNotNil(manifest.alignments.first(where: { $0.id == fixture.sourceTrackID }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundleURL.appendingPathComponent(derivedTrack.sourcePath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundleURL.appendingPathComponent(derivedTrack.indexPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundleURL.appendingPathComponent(try XCTUnwrap(derivedTrack.metadataDBPath)).path))
    }

    func testRemovalServiceRejectsSourceAlignmentTrack() async throws {
        let fixture = try AlignmentFilterFixture.make(rootURL: tempDir, includeNMTag: true)

        await XCTAssertThrowsErrorAsync(
            try await BundleAlignmentTrackRemovalService().removeDerivedAlignmentTrack(
                bundleURL: fixture.bundleURL,
                trackID: fixture.sourceTrackID
            )
        ) { error in
            XCTAssertEqual(
                error as? BundleAlignmentTrackRemovalError,
                .notDerivedTrack(fixture.sourceTrackID)
            )
        }
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

    private func bundleProvenanceRelativePaths(in bundleURL: URL) throws -> [String] {
        let provenanceURL = bundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(at: provenanceURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL else { return nil }
            return url.path.replacingOccurrences(of: provenanceURL.path + "/", with: "")
        }
    }
}

private enum InjectedFilterProvenanceError: Error, Equatable {
    case failed
}

private struct AlignmentFilterFixture {
    let bundleURL: URL
    let sourceBAMURL: URL
    let referenceFASTAURL: URL
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
        let genomeURL = bundleURL.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(
            at: genomeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: genomeURL)
        try Data("chr1\t12\t6\t12\t13\n".utf8).write(to: genomeURL.appendingPathExtension("fai"))

        let sourceTrackID = "aln-source"
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "fixture.bundle",
            source: SourceInfo(organism: "Virus", assembly: "Fixture", database: "FixtureDB"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 12,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 12, offset: 6, lineBases: 12, lineWidth: 13),
                ]
            ),
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
            referenceFASTAURL: genomeURL,
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
            referenceFASTAURL: fixture.referenceFASTAURL,
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
    private let version: String
    private(set) var commands: [[String]] = []

    init(requiredSAMTags: Set<String>, version: String = "1.23") {
        self.requiredSAMTags = requiredSAMTags
        self.version = version
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

    func samtoolsVersion() async -> String {
        version
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
