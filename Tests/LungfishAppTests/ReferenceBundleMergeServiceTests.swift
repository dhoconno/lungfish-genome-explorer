import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Thread-safe capture box for observations made from inside the merge's `@Sendable`
/// probe closure, which fires on whatever thread the merge body is running on.
private final class MarkerObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasInProgress: Bool?
    private var _fired = false

    func record(_ inProgress: Bool) {
        lock.lock()
        _wasInProgress = inProgress
        _fired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasInProgress: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasInProgress
    }
}

@MainActor
final class ReferenceBundleMergeServiceTests: XCTestCase {
    private enum FixtureError: Error {
        case provenanceWriteFailed
    }

    func testMergeCreatesSequenceOnlyReferenceBundle() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Reference"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.name, "Merged Reference")
        XCTAssertEqual(manifest.annotations.count, 0)
        XCTAssertEqual(manifest.variants.count, 0)
        XCTAssertEqual(manifest.tracks.count, 0)
        XCTAssertNotNil(manifest.genome)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        XCTAssertEqual(provenance.workflowName, "lungfish reference merge")
        XCTAssertEqual(provenance.toolName, "lungfish-app")
        XCTAssertFalse(provenance.toolVersion.isEmpty)
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertNotNil(provenance.wallTimeSeconds)
        XCTAssertEqual(provenance.options.explicit["bundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["requestedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["resolvedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["mergeMode"]?.stringValue, "sequence-only")
        XCTAssertEqual(
            provenance.options.resolvedDefaults["annotationMerge"]?.stringValue,
            "no-annotations-in-sources"
        )
        XCTAssertEqual(provenance.options.resolvedDefaults["variantMerge"]?.stringValue, "unsupported")
        XCTAssertEqual(provenance.options.resolvedDefaults["trackMerge"]?.stringValue, "unsupported")
        XCTAssertEqual(provenance.options.explicit["outputBundle"]?.fileValue?.path, mergedURL.path)

        let genome = try XCTUnwrap(manifest.genome)
        let expectedGenomePath = mergedURL.appendingPathComponent(genome.path).path
        let outputPaths = provenance.outputs.map(\.path)
        XCTAssertTrue(outputPaths.contains(mergedURL.appendingPathComponent(BundleManifest.filename).path))
        XCTAssertTrue(outputPaths.contains(expectedGenomePath))
        XCTAssertTrue(provenance.outputs.allSatisfy { $0.path.hasPrefix(mergedURL.path) })
        for record in provenance.files {
            XCTAssertNotNil(record.checksumSHA256, "Missing checksum for \(record.path)")
            XCTAssertNotNil(record.fileSize, "Missing file size for \(record.path)")
        }
        XCTAssertTrue(
            provenance.steps.contains { $0.toolName == "NativeBundleBuilder.build" },
            "Reference merge provenance must preserve the nested builder step"
        )
        let builderStep = try XCTUnwrap(
            provenance.steps.first { $0.toolName == "NativeBundleBuilder.build" }
        )
        let builderReplayArgv = try XCTUnwrap(builderStep.durableReplayArgv)
        XCTAssertTrue(builderReplayArgv.contains("--identifier"))
        XCTAssertTrue(builderReplayArgv.contains("--output-directory"))
        let fastaFlagIndex = try XCTUnwrap(builderReplayArgv.firstIndex(of: "--fasta"))
        let replayFASTAPath = builderReplayArgv[builderReplayArgv.index(after: fastaFlagIndex)]
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayFASTAPath))
        XCTAssertFalse(replayFASTAPath.contains("reference-merge-"))
        XCTAssertFalse(replayFASTAPath.contains("ref-import-"))

        let sourceFASTAPaths = try [
            XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleA)).path,
            XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleB)).path,
        ]
        let builderInputPaths = Set(builderStep.inputs.map(\.path))
        for sourceFASTAPath in sourceFASTAPaths {
            XCTAssertTrue(builderInputPaths.contains(sourceFASTAPath))
        }
        XCTAssertNotEqual(builderStep.argv, builderReplayArgv)
        XCTAssertTrue(builderStep.argv.joined(separator: "\n").contains("reference-merge-"))
        XCTAssertTrue(
            provenance.steps.contains { $0.toolName == "lungfish reference merge" },
            "Reference merge provenance must include the wrapping merge workflow step"
        )

        var durableProvenanceLines = provenance.argv
        durableProvenanceLines.append(provenance.reproducibleCommand)
        durableProvenanceLines.append(contentsOf: provenance.files.map(\.path))
        for step in provenance.steps {
            durableProvenanceLines.append(contentsOf: step.durableReplayArgv ?? [])
            durableProvenanceLines.append(step.reproducibleCommand)
            durableProvenanceLines.append(contentsOf: step.inputs.map(\.path))
            durableProvenanceLines.append(contentsOf: step.outputs.map(\.path))
        }
        let durableProvenanceText = durableProvenanceLines.joined(separator: "\n")
        XCTAssertFalse(durableProvenanceText.contains("reference-merge-"))
        XCTAssertFalse(durableProvenanceText.contains("ref-import-"))
    }

    func testMergeProvenanceUsesResolvedReferenceNameWhenOutputNameIsUniquified() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingBundle = projectURL.appendingPathComponent("Merged_Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: existingBundle, withIntermediateDirectories: true)

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Reference"
        )
        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.name, "Merged Reference 2")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        XCTAssertEqual(provenance.options.explicit["requestedBundleName"]?.stringValue, "Merged Reference")
        XCTAssertEqual(provenance.options.explicit["resolvedBundleName"]?.stringValue, "Merged Reference 2")
        XCTAssertEqual(provenance.options.explicit["bundleName"]?.stringValue, "Merged Reference 2")
        XCTAssertTrue(provenance.argv.contains("Merged Reference 2"))
        XCTAssertFalse(provenance.argv.contains("Merged Reference.lungfishref"))
    }

    func testMergeRejectsSourceBundleWithVariantTracks() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        let sequenceOnlyBundle = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let variantBundle = try makeVariantReferenceBundle(in: projectURL)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [sequenceOnlyBundle, variantBundle],
                outputDirectory: projectURL,
                bundleName: "Should Not Merge"
            )
            XCTFail("Expected variant-bearing reference bundles to be rejected")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("variant tracks"),
                "Refusal must name the unsupported payload precisely: \(message)"
            )
            XCTAssertFalse(
                message.contains("contains annotations, variants, tracks, or alignments"),
                "Refusal must no longer claim annotations are unsupported: \(message)"
            )
            XCTAssertTrue(
                message.lowercased().contains("annotation"),
                "Refusal must tell the user annotations now merge: \(message)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Should Not Merge.lungfishref").path
            )
        )
    }

    func testMergePreservesAnnotationsFromTwoGenBankBundles() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let genBankA = root.appendingPathComponent("A.gb")
        let genBankB = root.appendingPathComponent("B.gb")
        try Self.genBankRecord(
            locus: "GBSEQA",
            geneName: "geneA",
            sequence: "atcgatcgatcgatcgatcg"
        ).write(to: genBankA, atomically: true, encoding: .utf8)
        try Self.genBankRecord(
            locus: "GBSEQB",
            geneName: "geneB",
            sequence: "ggccggccggccggccggcc"
        ).write(to: genBankB, atomically: true, encoding: .utf8)

        let bundleA = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankA,
            outputDirectory: projectURL,
            preferredBundleName: "GenBank A"
        ).bundleURL
        let bundleB = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankB,
            outputDirectory: projectURL,
            preferredBundleName: "GenBank B"
        ).bundleURL

        // Sanity: both sources really do carry annotation tracks.
        XCTAssertFalse(try BundleManifest.load(from: bundleA).annotations.isEmpty)
        XCTAssertFalse(try BundleManifest.load(from: bundleB).annotations.isEmpty)

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged GenBank"
        )

        let manifest = try BundleManifest.load(from: mergedURL)

        // Both sequence sets survive.
        let chromosomeNames = Set((manifest.genome?.chromosomes ?? []).map(\.name))
        XCTAssertTrue(chromosomeNames.contains("GBSEQA"), "Merged genome missing GBSEQA: \(chromosomeNames)")
        XCTAssertTrue(chromosomeNames.contains("GBSEQB"), "Merged genome missing GBSEQB: \(chromosomeNames)")

        // Both annotation track sets survive, attributable to their origin bundle.
        XCTAssertEqual(manifest.annotations.count, 2, "Expected one annotation track per source bundle")
        let trackIDs = Set(manifest.annotations.map(\.id))
        XCTAssertEqual(trackIDs.count, 2, "Annotation track ids must be unique: \(trackIDs)")

        var mergedGenes: Set<String> = []
        var mergedChromosomes: Set<String> = []
        for track in manifest.annotations {
            let databasePath = try XCTUnwrap(track.databasePath, "Track \(track.id) lost its annotation database")
            let databaseURL = try BundleManifest.validatedBundleMemberURL(
                for: databasePath,
                in: mergedURL,
                field: "annotations.database_path"
            )
            let database = try AnnotationDatabase(url: databaseURL)
            for record in database.query(limit: Int.max) {
                mergedGenes.insert(record.name)
                mergedChromosomes.insert(record.chromosome)
            }
        }
        XCTAssertTrue(mergedGenes.contains("geneA"), "Merged annotations missing geneA: \(mergedGenes)")
        XCTAssertTrue(mergedGenes.contains("geneB"), "Merged annotations missing geneB: \(mergedGenes)")
        XCTAssertEqual(
            mergedChromosomes,
            ["GBSEQA", "GBSEQB"],
            "Annotations must stay bound to their original sequence names"
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        XCTAssertEqual(provenance.options.explicit["mergeMode"]?.stringValue, "sequence-and-annotations")
        XCTAssertEqual(
            provenance.options.resolvedDefaults["annotationMerge"]?.stringValue,
            "preserved"
        )
    }

    func testMergePreservesGenBankRecordStoreAcrossSources() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let genBankA = root.appendingPathComponent("A.gb")
        let genBankB = root.appendingPathComponent("B.gb")
        try Self.genBankRecord(
            locus: "STOREA",
            geneName: "geneA",
            sequence: "atcgatcgatcgatcgatcg"
        ).write(to: genBankA, atomically: true, encoding: .utf8)
        try Self.genBankRecord(
            locus: "STOREB",
            geneName: "geneB",
            sequence: "ggccggccggccggccggcc"
        ).write(to: genBankB, atomically: true, encoding: .utf8)

        let bundleA = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankA,
            outputDirectory: projectURL,
            preferredBundleName: "Store A"
        ).bundleURL
        let bundleB = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankB,
            outputDirectory: projectURL,
            preferredBundleName: "Store B"
        ).bundleURL

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Merged Store"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        let recordStore = try XCTUnwrap(
            manifest.recordStore,
            "Merged bundle dropped the GenBank record store"
        )
        XCTAssertEqual(recordStore.recordCount, 2)

        let bundle = try await ReferenceBundle(url: mergedURL)
        let database = try XCTUnwrap(bundle.recordStoreDatabase())
        let rows = try database.records()
        XCTAssertEqual(rows.map(\.sequenceName), ["STOREA", "STOREB"])
        XCTAssertEqual(rows.map(\.sourceOrdinal), [0, 1])
        XCTAssertTrue(
            rows.allSatisfy { $0.values["record.ACCESSION"] != nil },
            "Merged record store lost per-record ACCESSION metadata"
        )
    }

    func testMergeCombinesGenBankAndFASTASources() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let genBank = root.appendingPathComponent("Mixed.gb")
        try Self.genBankRecord(
            locus: "MIXEDGB",
            geneName: "geneMixed",
            sequence: "atcgatcgatcgatcgatcg"
        ).write(to: genBank, atomically: true, encoding: .utf8)
        let fasta = root.appendingPathComponent("Mixed.fa")
        try ">MIXEDFA\nACGTACGTACGT\n".write(to: fasta, atomically: true, encoding: .utf8)

        let genBankBundle = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBank,
            outputDirectory: projectURL,
            preferredBundleName: "Mixed GenBank"
        ).bundleURL
        let fastaBundle = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: fasta,
            outputDirectory: projectURL,
            preferredBundleName: "Mixed FASTA"
        ).bundleURL

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [genBankBundle, fastaBundle],
            outputDirectory: projectURL,
            bundleName: "Mixed Merge"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        let chromosomeNames = Set((manifest.genome?.chromosomes ?? []).map(\.name))
        XCTAssertEqual(chromosomeNames, ["MIXEDGB", "MIXEDFA"])
        XCTAssertEqual(
            manifest.annotations.count,
            1,
            "The GenBank source's annotations must survive a mixed merge"
        )
        // Only one source carries a record store, so the store is dropped rather than
        // written half-populated — but the loss must be recorded, not silent.
        XCTAssertNil(manifest.recordStore)
        XCTAssertTrue(
            manifest.warnings.contains { $0.code == "partial_record_store_dropped" },
            "Dropping the record store must leave a warning in the merged manifest"
        )
    }

    func testMergeWarnsWhenAnnotationTrackCannotBeReExported() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let genBank = root.appendingPathComponent("Readable.gb")
        try Self.genBankRecord(
            locus: "READABLE",
            geneName: "geneReadable",
            sequence: "atcgatcgatcgatcgatcg"
        ).write(to: genBank, atomically: true, encoding: .utf8)
        let readableBundle = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBank,
            outputDirectory: projectURL,
            preferredBundleName: "Readable"
        ).bundleURL

        // A track declaring no databasePath: the legacy/placeholder shape the merge cannot
        // re-read. It must be skipped with a warning, not silently, and not fatally.
        let legacyBundle = try makeLegacyAnnotationBundle(in: projectURL)

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [readableBundle, legacyBundle],
            outputDirectory: projectURL,
            bundleName: "Partial Annotations"
        )

        let manifest = try BundleManifest.load(from: mergedURL)

        // The readable track still came across; the merge did not abort.
        XCTAssertEqual(manifest.annotations.count, 1)

        let warning = try XCTUnwrap(
            manifest.warnings.first { $0.code == "annotation_track_dropped" },
            "Skipping an unreadable annotation track must leave a warning in the merged manifest"
        )
        XCTAssertEqual(warning.category, "merge.annotations")
        XCTAssertTrue(
            warning.message.contains("Legacy Genes"),
            "Warning must name the dropped track: \(warning.message)"
        )
        XCTAssertTrue(
            warning.message.contains("LegacyAnnotated"),
            "Warning must name the bundle the track came from: \(warning.message)"
        )
    }

    func testMergeDisambiguatesTracksFromIdenticallyNamedSourceBundles() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Both bundles ask for the SAME preferred name, so the importer uniquifies the
        // second to "Same Name 2" on disk while both still carry a track whose id is
        // "imported_annotations". Without the usedSlugs dedup in inspectSourceBundles both
        // tracks would namespace to the same id and their exported GFF3 files would collide
        // in the temp directory -- the second silently overwriting the first.
        let genBankA = root.appendingPathComponent("A.gb")
        let genBankB = root.appendingPathComponent("B.gb")
        try Self.genBankRecord(
            locus: "DEDUPA",
            geneName: "geneDedupA",
            sequence: "atcgatcgatcgatcgatcg"
        ).write(to: genBankA, atomically: true, encoding: .utf8)
        try Self.genBankRecord(
            locus: "DEDUPB",
            geneName: "geneDedupB",
            sequence: "ggccggccggccggccggcc"
        ).write(to: genBankB, atomically: true, encoding: .utf8)

        let bundleA = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankA,
            outputDirectory: projectURL,
            preferredBundleName: "Same Name"
        ).bundleURL
        let bundleB = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
            sourceURL: genBankB,
            outputDirectory: projectURL,
            preferredBundleName: "Same Name"
        ).bundleURL
        XCTAssertNotEqual(bundleA, bundleB)

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Dedup Merge"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.annotations.count, 2, "Both tracks must survive")
        XCTAssertEqual(
            Set(manifest.annotations.map(\.id)).count,
            2,
            "Track ids must be disambiguated: \(manifest.annotations.map(\.id))"
        )
        XCTAssertNoThrow(
            try manifest.annotations.forEach { track in
                let databasePath = try XCTUnwrap(track.databasePath)
                let url = try BundleManifest.validatedBundleMemberURL(
                    for: databasePath,
                    in: mergedURL,
                    field: "annotations.database_path"
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        )

        // The real proof the exports did not overwrite each other: both genes are present.
        var mergedGenes: Set<String> = []
        for track in manifest.annotations {
            let databasePath = try XCTUnwrap(track.databasePath)
            let databaseURL = try BundleManifest.validatedBundleMemberURL(
                for: databasePath,
                in: mergedURL,
                field: "annotations.database_path"
            )
            for record in try AnnotationDatabase(url: databaseURL).query(limit: Int.max) {
                mergedGenes.insert(record.name)
            }
        }
        XCTAssertTrue(mergedGenes.contains("geneDedupA"), "Lost track A's features: \(mergedGenes)")
        XCTAssertTrue(mergedGenes.contains("geneDedupB"), "Lost track B's features: \(mergedGenes)")
    }

    /// Regression test for a round-2 fix: `trackID` in `exportAnnotationInputs` is built as
    /// `"\(source.namespaceSlug)_\(slugify(track.id))"`. `namespaceSlug` is deduped PER SOURCE
    /// BUNDLE (`usedSlugs` in `inspectSourceBundles`), but that gives zero protection against
    /// two DIFFERENT `track.id` values within the SAME bundle slugifying to the same string --
    /// e.g. "Genes v1" and "Genes-v1" both collapse to "genes_v1" under `slugify` (any run of
    /// non-alphanumeric characters maps to a single underscore). Without a `usedTrackIDs`
    /// dedup, the second track's export would silently overwrite the first's GFF3 file on
    /// disk (both share the same `exportURL`, built directly from `trackID`), and the merged
    /// manifest would end up with two `AnnotationTrackInfo`s sharing one `id`.
    func testMergeDisambiguatesTracksWhoseIdsSlugifyIdenticallyWithinOneBundle() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = try makeBundleWithSlugCollidingTracks(
            in: projectURL,
            firstTrackID: "Genes v1",
            firstGeneName: "geneSlugA",
            secondTrackID: "Genes-v1",
            secondGeneName: "geneSlugB"
        )

        // Merge requires at least two source bundles; this second bundle is
        // sequence-only (no annotations) and exists purely to satisfy that
        // requirement without affecting the collision under test.
        let plainFASTA = root.appendingPathComponent("Plain.fa")
        try ">PLAINSEQ\nACGTACGTACGT\n".write(to: plainFASTA, atomically: true, encoding: .utf8)
        let plainBundleURL = try ReferenceSequenceFolder.importReference(
            from: plainFASTA,
            into: projectURL,
            displayName: "Plain"
        )

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleURL, plainBundleURL],
            outputDirectory: projectURL,
            bundleName: "Slug Collision Merge"
        )

        let manifest = try BundleManifest.load(from: mergedURL)
        XCTAssertEqual(manifest.annotations.count, 2, "Both slug-colliding tracks must survive")
        XCTAssertEqual(
            Set(manifest.annotations.map(\.id)).count,
            2,
            "Track ids must be disambiguated even when they slugify identically: \(manifest.annotations.map(\.id))"
        )

        // The real proof the exports did not overwrite each other: both genes are present.
        var mergedGenes: Set<String> = []
        for track in manifest.annotations {
            let databasePath = try XCTUnwrap(track.databasePath)
            let databaseURL = try BundleManifest.validatedBundleMemberURL(
                for: databasePath,
                in: mergedURL,
                field: "annotations.database_path"
            )
            for record in try AnnotationDatabase(url: databaseURL).query(limit: Int.max) {
                mergedGenes.insert(record.name)
            }
        }
        XCTAssertTrue(mergedGenes.contains("geneSlugA"), "Lost the first slug-colliding track's features: \(mergedGenes)")
        XCTAssertTrue(mergedGenes.contains("geneSlugB"), "Lost the second slug-colliding track's features: \(mergedGenes)")
    }

    func testMergeMarksOutputDirectoryInProgressAndClearsItAfterwards() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrMarkerA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrMarkerB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "Marker A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "Marker B"
        )

        XCTAssertFalse(OperationMarker.isInProgress(projectURL))

        // Observe the marker from inside the merge. The probe fires while the merge body is
        // running, which is the only window in which the crash-recovery sentinel exists.
        let markerBox = MarkerObservationBox()
        let observedDirectory = projectURL
        ReferenceBundleMergeService.recordStoreThreadingProbe = {
            markerBox.record(OperationMarker.isInProgress(observedDirectory))
        }
        defer { ReferenceBundleMergeService.recordStoreThreadingProbe = nil }

        let mergedURL = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: [bundleA, bundleB],
            outputDirectory: projectURL,
            bundleName: "Marker Merge"
        )

        XCTAssertTrue(markerBox.fired, "Probe never fired -- merge body did not run")
        XCTAssertEqual(
            markerBox.wasInProgress,
            true,
            "Output directory must carry the .processing marker while the merge runs"
        )
        XCTAssertFalse(
            OperationMarker.isInProgress(projectURL),
            "The .processing marker must be cleared once the merge finishes"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL.path))
    }

    func testMergeClearsInProgressMarkerWhenMergeFails() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrFailA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrFailB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "Fail A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "Fail B"
        )

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, bundleB],
                outputDirectory: projectURL,
                bundleName: "Failed Marker",
                provenanceWriter: BundleMergeProvenanceSidecarWriter { _, _ in
                    throw FixtureError.provenanceWriteFailed
                }
            )
            XCTFail("Expected merge to fail when provenance cannot be written")
        } catch FixtureError.provenanceWriteFailed {
            // Expected.
        }

        XCTAssertFalse(
            OperationMarker.isInProgress(projectURL),
            "A failed merge must not leave the output directory marked in progress"
        )
    }

    func testMergeRefusesManifestThatMatchesNeitherSchema() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )

        // Valid JSON that decodes as NEITHER BundleManifest NOR ReferenceSequenceManifest.
        // This is the actual discrimination boundary: the corrupt-JSON test only proves the
        // JSON parser rejects garbage, whereas this proves we distinguish "known-safe legacy
        // schema" from "schema we do not recognise" rather than waving the latter through.
        let unknownBundle = projectURL.appendingPathComponent("UnknownSchema.lungfishref", isDirectory: true)
        let genomeDirectory = unknownBundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try ">chrU\nTTTT\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"name":"x"}"#.write(
            to: unknownBundle.appendingPathComponent(BundleManifest.filename),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, unknownBundle],
                outputDirectory: projectURL,
                bundleName: "Should Not Merge"
            )
            XCTFail("Expected a manifest matching neither schema to refuse the merge")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("UnknownSchema"),
                "Refusal must name the offending bundle: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Should_Not_Merge.lungfishref").path
            )
        )
    }

    func testMergeRefusesSourceBundleWithUnreadableManifest() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )

        let corruptBundle = projectURL.appendingPathComponent("Corrupt.lungfishref", isDirectory: true)
        let genomeDirectory = corruptBundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try ">chrC\nGGGG\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "{ not valid json".write(
            to: corruptBundle.appendingPathComponent(BundleManifest.filename),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, corruptBundle],
                outputDirectory: projectURL,
                bundleName: "Should Not Merge"
            )
            XCTFail("Expected an unreadable manifest to refuse the merge")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Corrupt"),
                "Refusal must name the offending bundle: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Should_Not_Merge.lungfishref").path
            )
        )
    }

    func testMergeRefusesDuplicateSequenceNamesAcrossSources() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">shared\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">shared\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, bundleB],
                outputDirectory: projectURL,
                bundleName: "Colliding Merge"
            )
            XCTFail("Expected duplicate sequence names to refuse the merge")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("shared"),
                "Refusal must name the colliding record: \(message)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Colliding_Merge.lungfishref").path
            )
        )
    }

    func testMergeRemovesPartialReferenceBundleWhenProvenanceWriteFails() async throws {
        let root = try makeTempDirectory()
        let projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fastaA = root.appendingPathComponent("A.fa")
        let fastaB = root.appendingPathComponent("B.fa")
        try ">chrA\nAAAA\n".write(to: fastaA, atomically: true, encoding: .utf8)
        try ">chrB\nCCCC\n".write(to: fastaB, atomically: true, encoding: .utf8)

        let bundleA = try ReferenceSequenceFolder.importReference(
            from: fastaA,
            into: projectURL,
            displayName: "A"
        )
        let bundleB = try ReferenceSequenceFolder.importReference(
            from: fastaB,
            into: projectURL,
            displayName: "B"
        )
        let expectedOutput = projectURL.appendingPathComponent("Failed_Reference.lungfishref", isDirectory: true)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [bundleA, bundleB],
                outputDirectory: projectURL,
                bundleName: "Failed Reference",
                provenanceWriter: BundleMergeProvenanceSidecarWriter { _, _ in
                    throw FixtureError.provenanceWriteFailed
                }
            )
            XCTFail("Expected merge to fail when provenance cannot be written")
        } catch FixtureError.provenanceWriteFailed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOutput.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeVariantReferenceBundle(in projectURL: URL) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("WithVariants.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let variantsDirectory = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: variantsDirectory, withIntermediateDirectories: true)

        try ">chrB\nCCCC\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "placeholder\n".write(
            to: variantsDirectory.appendingPathComponent("calls.bcf"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: "WithVariants",
            identifier: "org.lungfish.test.withvariants",
            source: SourceInfo(organism: "WithVariants", assembly: "WithVariants"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chrB",
                        length: 4,
                        offset: 0,
                        lineBases: 4,
                        lineWidth: 5
                    )
                ]
            ),
            variants: [
                VariantTrackInfo(
                    id: "calls",
                    name: "Calls",
                    path: "variants/calls.bcf",
                    indexPath: "variants/calls.bcf.csi"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// A single reference bundle with two REAL (indexed, `.db`-backed) annotation tracks
    /// whose ids are distinct strings that `slugify` collapses to the same output -- e.g.
    /// "Genes v1" and "Genes-v1" both become "genes_v1" (`slugify` maps any run of
    /// non-alphanumeric characters to one underscore). `BundleManifest.validate()` only
    /// checks raw `track.id` string equality, so both pass manifest validation despite
    /// being a real post-slugify collision.
    private func makeBundleWithSlugCollidingTracks(
        in projectURL: URL,
        firstTrackID: String,
        firstGeneName: String,
        secondTrackID: String,
        secondGeneName: String
    ) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("SlugCollision.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDirectory = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)

        try ">SLUGSEQ\n\(String(repeating: "ACGT", count: 5))\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let firstBedURL = annotationsDirectory.appendingPathComponent("first-source.bed")
        try "SLUGSEQ\t1\t6\t\(firstGeneName)\t0\t+\n".write(to: firstBedURL, atomically: true, encoding: .utf8)
        let firstDatabaseURL = annotationsDirectory.appendingPathComponent("first.db")
        _ = try AnnotationDatabase.createFromBED(bedURL: firstBedURL, outputURL: firstDatabaseURL)

        let secondBedURL = annotationsDirectory.appendingPathComponent("second-source.bed")
        try "SLUGSEQ\t8\t14\t\(secondGeneName)\t0\t+\n".write(to: secondBedURL, atomically: true, encoding: .utf8)
        let secondDatabaseURL = annotationsDirectory.appendingPathComponent("second.db")
        _ = try AnnotationDatabase.createFromBED(bedURL: secondBedURL, outputURL: secondDatabaseURL)

        let manifest = BundleManifest(
            name: "SlugCollision",
            identifier: "org.lungfish.test.slugcollision",
            source: SourceInfo(organism: "SlugCollision", assembly: "SlugCollision"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "SLUGSEQ", length: 20, offset: 0, lineBases: 20, lineWidth: 21)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: firstTrackID,
                    name: firstTrackID,
                    path: "annotations/first.db",
                    databasePath: "annotations/first.db",
                    featureCount: 1
                ),
                AnnotationTrackInfo(
                    id: secondTrackID,
                    name: secondTrackID,
                    path: "annotations/second.db",
                    databasePath: "annotations/second.db",
                    featureCount: 1
                ),
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// A bundle whose annotation track declares no `databasePath`, the shape that predates
    /// indexed annotations. The merge cannot re-read such a track and must skip it with a
    /// warning rather than aborting or dropping it silently.
    private func makeLegacyAnnotationBundle(in projectURL: URL) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("LegacyAnnotated.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDirectory = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)

        try ">LEGACYSEQ\nCCCCCCCCCCCC\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "placeholder\n".write(
            to: annotationsDirectory.appendingPathComponent("genes.bb"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: "LegacyAnnotated",
            identifier: "org.lungfish.test.legacyannotated",
            source: SourceInfo(organism: "LegacyAnnotated", assembly: "LegacyAnnotated"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 12,
                chromosomes: [
                    ChromosomeInfo(
                        name: "LEGACYSEQ",
                        length: 12,
                        offset: 0,
                        lineBases: 12,
                        lineWidth: 13
                    )
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Legacy Genes",
                    path: "annotations/genes.bb"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// Builds a minimal single-record GenBank source with one gene feature.
    ///
    /// Kept inline (rather than depending on `test-data/`) so the fixture is
    /// available from fresh clones and worktrees.
    private static func genBankRecord(
        locus: String,
        geneName: String,
        sequence: String
    ) -> String {
        let length = sequence.count
        let originLine = "        1 " + sequence
        return """
        LOCUS       \(locus)                \(length) bp    DNA     linear   SYN 01-JAN-2024
        DEFINITION  Synthetic record \(locus) for reference merge tests.
        ACCESSION   \(locus)
        VERSION     \(locus).1
        FEATURES             Location/Qualifiers
             source          1..\(length)
                             /organism="Synthetic construct"
                             /mol_type="genomic DNA"
             gene            1..\(length)
                             /gene="\(geneName)"
                             /locus_tag="\(locus)_001"
        ORIGIN
        \(originLine)
        //

        """
    }
}
