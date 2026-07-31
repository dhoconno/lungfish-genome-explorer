import XCTest
import Darwin
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeExportSubcommandTests: XCTestCase {
    // MARK: - Argument parsing

    func testParsesFilterLensAndProjectionFlags() throws {
        // NOTE: the container format flag is `--export-format` (not
        // `--format`). `GlobalOptions`, included via `@OptionGroup` per the
        // binding rule, already owns `--format` (text/json/tsv), so the
        // export format gets a distinct long name to avoid a duplicate.
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--export-format", "csv",
            "--output", "/tmp/out.csv",
            "--lens", "haplotype",
            "--min-reads", "25",
            "--filter", "errors",
            "--sample", "S1",
            "--sample", "S2",
            "--active-haplotype-definition", "custom.def",
            "--view-projection", "/tmp/projection.json",
            "--force",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.format, .csv)
        XCTAssertEqual(command.output, "/tmp/out.csv")
        XCTAssertEqual(command.lens, "haplotype")
        XCTAssertEqual(command.minReads, 25)
        XCTAssertEqual(command.filter, "errors")
        XCTAssertEqual(command.samples, ["S1", "S2"])
        XCTAssertEqual(command.activeHaplotypeDefinition, "custom.def")
        XCTAssertEqual(command.viewProjection, "/tmp/projection.json")
        XCTAssertTrue(command.force)
    }

    func testRejectsEmptyBundle() {
        XCTAssertThrowsError(
            try GenotypeExportSubcommand.parse([
                "--bundle", "   ",
                "--export-format", "xlsx",
                "--output", "/tmp/out.xlsx",
            ]).validate()
        )
    }

    // MARK: - Projection round-trip

    func testViewProjectionRoundTripsThroughCodable() throws {
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    locus: "MHC-A",
                    stableClusterID: "cluster-001",
                    cells: ["M1A", "M2A"],
                    rowColorHex: "#D47B3A"
                )
            ],
            cellColorMode: "budde2010"
        )
        let data = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(GenotypeViewProjection.self, from: data)
        XCTAssertEqual(decoded, projection)
        XCTAssertEqual(decoded.rows.first?.stableClusterID, "cluster-001")
    }

    func testViewProjectionDecodesLegacyRowsWithoutLocus() throws {
        let legacyJSON = Data("""
        {
          "lens": "haplotype",
          "sampleColumns": ["S1"],
          "rows": [
            {
              "label": "01_M1A_A1_063",
              "cells": ["39"],
              "cellColorsHex": ["#FFF2CC"],
              "rowColorHex": null
            }
          ],
          "cellColorMode": "budde2010"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GenotypeViewProjection.self, from: legacyJSON)

        XCTAssertEqual(decoded.rows.first?.label, "01_M1A_A1_063")
        XCTAssertNil(decoded.rows.first?.locus)
        XCTAssertNil(decoded.rows.first?.stableClusterID)
        XCTAssertEqual(decoded.rows.first?.cells, ["39"])
    }

    // MARK: - Provenance

    func testGenotypeExportRecordsLungfishCliProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let out = root.appendingPathComponent("out.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--force",
        ])
        try await cmd.run()

        let prov = out.appendingPathExtension("lungfish-provenance.json")
        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: prov))
        XCTAssertEqual(env.toolName, "lungfish-cli")
        XCTAssertEqual(env.workflowName, "lungfish genotype export")
        XCTAssertEqual(env.exitStatus, 0)
        XCTAssertFalse(env.argv.isEmpty)
        XCTAssertTrue(env.argv.contains("export"))
        XCTAssertTrue(env.argv.contains("--force"))
        let outputDescriptor = try XCTUnwrap(
            (env.outputs + env.steps.flatMap(\.outputs)).first {
                URL(fileURLWithPath: $0.path).standardizedFileURL == out.standardizedFileURL
            }
        )
        XCTAssertNotNil(outputDescriptor.checksumSHA256)
        XCTAssertGreaterThan(outputDescriptor.fileSize ?? 0, 0)
    }

    func testProjectionExportUsesAttestedCatalogAndRecordsNativeFalseNegativeDecisions()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-native-fn-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let formulaLikeLabel = "=Mafa-A1*999:99"
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: fixture)
        var sidecar = snapshot.sidecar
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel,
                    sample: "S1"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel,
                    sample: "S2"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:01:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            expectedRevision: snapshot.revision,
            forBundleAt: fixture
        )
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1", "S2"],
            rows: [
                .init(
                    label: "Mafa-B*001:01",
                    locus: "MHC-B",
                    cells: ["12", "7"]
                ),
            ]
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        let outputURL = root.appendingPathComponent("native-fn.xlsx")
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--view-projection", projectionURL.path,
            "--force",
        ])

        try await command.run()

        let sheet = try unzipEntry(
            "xl/worksheets/sheet1.xml",
            from: outputURL
        )
        XCTAssertTrue(sheet.contains("Analyst annotation-only rows"))
        XCTAssertTrue(sheet.contains("<t>FN</t>"))
        XCTAssertFalse(sheet.contains("<f>"))

        let provenanceURL = outputURL.appendingPathExtension(
            "lungfish-provenance.json"
        )
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL)
        )
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(
            resolved["nativeWorkbookAdapterVersion"],
            .string("native-view-projection-v1")
        )
        XCTAssertEqual(
            resolved["nativeFalseNegativeRestorationDecision"],
            .string("fresh-projection-rebuild-no-managed-state-restoration")
        )
        guard case let .array(synthesis)? =
            resolved["nativeFalseNegativeSynthesisDecisions"] else {
            return XCTFail("missing structured synthesis decisions")
        }
        XCTAssertEqual(synthesis.count, 1)
        guard case let .array(targets)? =
            resolved["nativeFalseNegativeTargetCellDecisions"] else {
            return XCTFail("missing structured target-cell decisions")
        }
        XCTAssertEqual(targets.count, 2)
        guard case let .dictionary(descriptor)? =
            resolved["reviewableRowCatalogDescriptor"] else {
            return XCTFail("missing authoritative catalog descriptor")
        }
        let catalogURL = fixture.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        XCTAssertEqual(
            descriptor["path"],
            .string("artifacts/review/reviewable-row-catalog.json")
        )
        XCTAssertEqual(
            descriptor["schemaID"],
            .string(GenotypeReviewableRowCatalog.schemaID)
        )
        XCTAssertEqual(
            descriptor["sha256"],
            .string(try ProvenanceFileHasher.sha256(of: catalogURL))
        )
        XCTAssertEqual(
            descriptor["sizeBytes"],
            .integer(
                Int(
                    clamping: try ProvenanceFileHasher.fileSize(of: catalogURL)
                )
            )
        )
        let catalogInput = try XCTUnwrap(envelope.files.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL
                == catalogURL.standardizedFileURL
                && $0.role == .input
        })
        XCTAssertEqual(
            catalogInput.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: catalogURL)
        )
        XCTAssertEqual(
            catalogInput.fileSize,
            try ProvenanceFileHasher.fileSize(of: catalogURL)
        )
    }

    func testProjectionExportProvenanceBindsConsumedSnapshotsAfterInputDeletionOrMutation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-input-snapshot-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let annotationURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: fixture)
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: fixture)
        var sidecar = snapshot.sidecar
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "=Mafa-A1*999:99",
                    sample: "S1"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            expectedRevision: snapshot.revision,
            forBundleAt: fixture
        )
        let catalogURL = fixture.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        let consumedAnnotationSHA = try ProvenanceFileHasher.sha256(
            of: annotationURL
        )
        let consumedCatalogSHA = try ProvenanceFileHasher.sha256(of: catalogURL)
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: []
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        let outputURL = root.appendingPathComponent("snapshot-bound.xlsx")
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--view-projection", projectionURL.path,
            "--force",
        ])

        try await command.runReturningResolvedColumns(
            beforeProvenancePublication: {
                try FileManager.default.removeItem(at: annotationURL)
                try Data(#"{"swapped":"catalog"}"#.utf8).write(
                    to: catalogURL,
                    options: .atomic
                )
            }
        )

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(
                fromSidecar: outputURL.appendingPathExtension(
                    "lungfish-provenance.json"
                )
            )
        )
        let descriptors = envelope.files + envelope.steps.flatMap(\.inputs)
        for (url, expectedSHA) in [
            (annotationURL, consumedAnnotationSHA),
            (catalogURL, consumedCatalogSHA),
        ] {
            let matching = descriptors.filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == url.standardizedFileURL
                    && $0.role == .input
            }
            XCTAssertFalse(matching.isEmpty)
            XCTAssertTrue(
                matching.allSatisfy { $0.checksumSHA256 == expectedSHA },
                "provenance must describe the bytes consumed before publication"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: annotationURL.path))
        XCTAssertNotEqual(
            try ProvenanceFileHasher.sha256(of: catalogURL),
            consumedCatalogSHA,
            "the mutation hook must prove the catalog changed"
        )
    }

    func testProjectionExportDoesNotClaimAnnotationSidecarCreatedAfterRender()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-late-annotation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let annotationURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: fixture)
        try FileManager.default.removeItem(at: annotationURL)
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: [
                .init(
                    label: "Mafa-B*001:01",
                    locus: "MHC-B",
                    cells: ["12"]
                ),
            ]
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        let outputURL = root.appendingPathComponent("late-annotation.xlsx")
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--view-projection", projectionURL.path,
            "--force",
        ])

        try await command.runReturningResolvedColumns(
            beforeProvenancePublication: {
                try Data(#"{"late":"annotation"}"#.utf8).write(
                    to: annotationURL,
                    options: .atomic
                )
            }
        )

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(
                fromSidecar: outputURL.appendingPathExtension(
                    "lungfish-provenance.json"
                )
            )
        )
        let inputDescriptors = envelope.files + envelope.steps.flatMap(\.inputs)
        XCTAssertFalse(inputDescriptors.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL
                == annotationURL.standardizedFileURL
        })
        XCTAssertFalse(envelope.argv.contains("--annotations"))
        XCTAssertNil(envelope.options.explicit["annotations"])
        XCTAssertNotEqual(
            envelope.options.resolvedDefaults["annotations"],
            .file(annotationURL)
        )
    }

    func testProjectionExportProvenanceBindsConsumedProjectionAfterMutationOrDeletion()
        async throws
    {
        for deleteProjection in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "genotype-export-projection-snapshot-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let fixture = try makeGenotypeBundleFixture(in: root)
            let projection = GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [
                    .init(
                        label: "Mafa-B*001:01",
                        locus: "MHC-B",
                        cells: ["12"]
                    ),
                ]
            )
            let projectionURL = root.appendingPathComponent("projection.json")
            let consumedData = try JSONEncoder().encode(projection)
            try consumedData.write(to: projectionURL)
            let consumedSHA = try ProvenanceFileHasher.sha256(of: projectionURL)
            let outputURL = root.appendingPathComponent(
                deleteProjection ? "deleted.xlsx" : "mutated.xlsx"
            )
            let command = try GenotypeExportSubcommand.parse([
                "--bundle", fixture.path,
                "--export-format", "xlsx",
                "--output", outputURL.path,
                "--view-projection", projectionURL.path,
            ])

            try await command.runReturningResolvedColumns(
                beforeProvenancePublication: {
                    if deleteProjection {
                        try FileManager.default.removeItem(at: projectionURL)
                    } else {
                        try Data(#"{"replacement":true}"#.utf8).write(
                            to: projectionURL,
                            options: .atomic
                        )
                    }
                }
            )

            let envelope = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(
                    fromSidecar: outputURL.appendingPathExtension(
                        "lungfish-provenance.json"
                    )
                )
            )
            let projectionInputs = (
                envelope.files + envelope.steps.flatMap(\.inputs)
            ).filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == projectionURL.standardizedFileURL
                    && $0.role == .input
            }
            XCTAssertFalse(projectionInputs.isEmpty)
            XCTAssertTrue(
                projectionInputs.allSatisfy {
                    $0.checksumSHA256 == consumedSHA
                        && $0.fileSize == UInt64(consumedData.count)
                },
                "provenance must bind the projection bytes used to render"
            )
            if deleteProjection {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: projectionURL.path)
                )
            } else {
                XCTAssertNotEqual(
                    try ProvenanceFileHasher.sha256(of: projectionURL),
                    consumedSHA
                )
            }
        }
    }

    func testImplicitAnnotationSnapshotAtomicallyTracksAppearanceAndDeletion()
        async throws
    {
        for shouldAppear in [true, false] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "genotype-export-atomic-annotation-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let fixture = try makeGenotypeBundleFixture(in: root)
            let annotationURL = ONTGenotypeResultBundleData
                .annotationSidecarURL(forBundleAt: fixture)
            if shouldAppear {
                try FileManager.default.removeItem(at: annotationURL)
            }
            let expectedData = try JSONEncoder().encode(
                GenotypeAnnotationSidecar.empty(
                    generatedAt: "2026-07-27T02:00:00Z"
                )
            )
            let outputURL = root.appendingPathComponent(
                shouldAppear ? "appeared.xlsx" : "deleted.xlsx"
            )
            let command = try GenotypeExportSubcommand.parse([
                "--bundle", fixture.path,
                "--export-format", "xlsx",
                "--output", outputURL.path,
            ])

            try await command.runReturningResolvedColumns(
                beforeAnnotationSnapshot: {
                    if shouldAppear {
                        try expectedData.write(
                            to: annotationURL,
                            options: .atomic
                        )
                    } else {
                        try FileManager.default.removeItem(at: annotationURL)
                    }
                }
            )

            let envelope = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(
                    fromSidecar: outputURL.appendingPathExtension(
                        "lungfish-provenance.json"
                    )
                )
            )
            let annotationInputs = (
                envelope.files + envelope.steps.flatMap(\.inputs)
            ).filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == annotationURL.standardizedFileURL
                    && $0.role == .input
            }
            if shouldAppear {
                XCTAssertFalse(annotationInputs.isEmpty)
                XCTAssertTrue(envelope.argv.contains("--annotations"))
                XCTAssertTrue(annotationInputs.allSatisfy {
                    $0.checksumSHA256
                        == (try? ProvenanceFileHasher.sha256(of: annotationURL))
                })
            } else {
                XCTAssertTrue(annotationInputs.isEmpty)
                XCTAssertFalse(envelope.argv.contains("--annotations"))
            }
        }
    }

    func testProjectionExportRejectsTamperedCatalogBeforePublishingWorkbook()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-native-fn-tampered-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: fixture)
        var sidecar = snapshot.sidecar
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "=Mafa-A1*999:99",
                    sample: "S1"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            expectedRevision: snapshot.revision,
            forBundleAt: fixture
        )
        let catalogURL = fixture.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        var tampered = try Data(contentsOf: catalogURL)
        tampered.append(Data("\n ".utf8))
        try tampered.write(to: catalogURL)
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: []
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        let outputURL = root.appendingPathComponent("must-not-exist.xlsx")
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--view-projection", projectionURL.path,
            "--force",
        ])

        do {
            try await command.run()
            XCTFail("expected catalog checksum failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testExportRestoresPriorOutputWhenProvenancePublicationFails()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-provenance-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("existing.xlsx")
        let outputSidecarURL = ProvenanceRecorder.fileSidecarURL(
            for: outputURL
        )
        let rootProvenanceURL = root.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let priorOutput = Data("prior workbook".utf8)
        let priorSidecar = Data("prior output provenance".utf8)
        let priorRootProvenance = Data("prior root provenance".utf8)
        try priorOutput.write(to: outputURL)
        try priorSidecar.write(to: outputSidecarURL)
        try priorRootProvenance.write(to: rootProvenanceURL)
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--force",
        ])
        do {
            try await command.runReturningResolvedColumns(
                beforeProvenancePublication: {
                    throw NSError(
                        domain: "GenotypeExportSubcommandTests",
                        code: 91,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Injected provenance publication failure",
                        ]
                    )
                }
            )
            XCTFail("expected injected provenance failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Injected provenance publication failure"
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), priorOutput)
        XCTAssertEqual(try Data(contentsOf: outputSidecarURL), priorSidecar)
        XCTAssertEqual(
            try Data(contentsOf: rootProvenanceURL),
            priorRootProvenance
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.contains("export-staging") })
    }

    func testRollbackPreservesNoncooperatingWriterChanges()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-cas-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("shared.xlsx")
        let outputSidecarURL = ProvenanceRecorder.fileSidecarURL(
            for: outputURL
        )
        let rootProvenanceURL = root.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let provenanceDirectoryURL = root.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        let provenanceGenerationURL = provenanceDirectoryURL
            .appendingPathComponent("bundle-provenance.json")
        try FileManager.default.createDirectory(
            at: provenanceDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("prior workbook".utf8).write(to: outputURL)
        try Data("prior output provenance".utf8).write(to: outputSidecarURL)
        try Data("prior root provenance".utf8).write(to: rootProvenanceURL)
        try Data("prior provenance generation".utf8).write(
            to: provenanceGenerationURL
        )
        let priorGenerationInode = try inode(of: provenanceGenerationURL)

        let externalOutput = Data("noncooperating workbook".utf8)
        let externalRootProvenance = Data(
            "noncooperating root provenance".utf8
        )
        let externalGeneration = Data(
            "noncooperating provenance generation".utf8
        )
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--force",
        ])
        var externalWriterFired = false
        var externalRootInode: UInt64?
        var failureDescription = ""

        do {
            try await command.runReturningResolvedColumns(
                beforeProvenanceArtifactObservation: { mutation in
                    if mutation.kind == .provenanceDocumentWritten,
                       mutation.url.standardizedFileURL
                        == rootProvenanceURL.standardizedFileURL,
                       !externalWriterFired {
                        // This actor intentionally does not acquire Lungfish's
                        // export lock. A later, unrelated provenance mutation
                        // must not adopt these bytes into this transaction's
                        // rollback witness.
                        externalWriterFired = true
                        try externalOutput.write(
                            to: outputURL,
                            options: .atomic
                        )
                        try self.overwriteInPlace(
                            rootProvenanceURL,
                            with: externalRootProvenance
                        )
                        externalRootInode = try self.inode(
                            of: rootProvenanceURL
                        )
                        try self.overwriteInPlace(
                            provenanceGenerationURL,
                            with: externalGeneration
                        )
                        return
                    }
                },
                afterProvenanceArtifactPublication: { mutation in
                    guard mutation.kind == .provenanceDocumentWritten,
                          mutation.url.standardizedFileURL
                            == outputSidecarURL.standardizedFileURL else {
                        return
                    }
                    throw NSError(
                        domain: "GenotypeExportSubcommandTests",
                        code: 96,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Injected failure after later provenance mutation",
                        ]
                    )
                }
            )
            XCTFail("expected injected publication failure")
        } catch {
            failureDescription = String(describing: error)
            XCTAssertTrue(
                failureDescription.contains(
                    "Injected failure after later provenance mutation"
                )
            )
            XCTAssertTrue(
                failureDescription.contains(outputURL.path),
                "partial rollback diagnostics must name preserved paths"
            )
        }

        XCTAssertTrue(externalWriterFired)
        XCTAssertEqual(try Data(contentsOf: outputURL), externalOutput)
        XCTAssertEqual(
            try Data(contentsOf: rootProvenanceURL),
            externalRootProvenance
        )
        XCTAssertEqual(
            try Data(contentsOf: outputSidecarURL),
            Data("prior output provenance".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: provenanceGenerationURL),
            externalGeneration
        )
        XCTAssertEqual(
            try inode(of: rootProvenanceURL),
            externalRootInode,
            "root provenance mutation must exercise same-inode CAS"
        )
        XCTAssertEqual(
            try inode(of: provenanceGenerationURL),
            priorGenerationInode,
            "provenance tree mutation must exercise same-inode CAS"
        )
        let preservedPriorWorkbookURLs = try FileManager.default
            .contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.hasPrefix(
                    ".shared.xlsx.provenance-forward-"
                )
            }
        XCTAssertEqual(preservedPriorWorkbookURLs.count, 1)
        let preservedPriorWorkbookURL = try XCTUnwrap(
            preservedPriorWorkbookURLs.first
        )
        XCTAssertEqual(
            try Data(contentsOf: preservedPriorWorkbookURL),
            Data("prior workbook".utf8)
        )
        XCTAssertTrue(
            failureDescription.contains(
                preservedPriorWorkbookURL.lastPathComponent
            ),
            "partial rollback diagnostics must name the prior workbook quarantine: \(failureDescription)"
        )
    }

    func testRollbackSnapshotRejectsChangeBetweenBackupAndBoundWitness()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "genotype-export-snapshot-race-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let outputURL = root.appendingPathComponent("shared.xlsx")
        let original = Data("original-generation".utf8)
        let external = Data("external-generation".utf8)
        try original.write(to: outputURL)

        XCTAssertThrowsError(
            try ProvenancePublicationSnapshot(
                urls: [outputURL],
                afterBackupCopy: { copiedURL in
                    XCTAssertEqual(
                        copiedURL.standardizedFileURL,
                        outputURL.standardizedFileURL
                    )
                    try external.write(
                        to: outputURL,
                        options: .atomic
                    )
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "changed while its rollback snapshot"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), external)
    }

    func testForceExportDoesNotDeleteReplacementArrivingBeforeClaim()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "genotype-export-forward-claim-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("shared.xlsx")
        let prior = Data("prior generation".utf8)
        let external = Data("external generation".utf8)
        try prior.write(to: outputURL)
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--force",
        ])

        do {
            try await command.runReturningResolvedColumns(
                beforeOutputReplacementClaim: {
                    try external.write(
                        to: outputURL,
                        options: .atomic
                    )
                }
            )
            XCTFail("expected generation conflict")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(outputURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), external)
    }

    func testRollbackRestoresAfterEachPublishedProvenanceArtifact()
        async throws
    {
        enum FailureTarget: String, CaseIterable {
            case root
            case bundleRollup
            case focusedBundleSidecar
            case outputSidecar
        }

        for failureTarget in FailureTarget.allCases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "genotype-export-artifact-rollback-\(failureTarget.rawValue)-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let fixture = try makeGenotypeBundleFixture(in: root)
            let publicationRoot = root.appendingPathComponent(
                "publication.lungfishresults",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: publicationRoot,
                withIntermediateDirectories: true
            )
            let outputURL = publicationRoot.appendingPathComponent(
                "existing.xlsx"
            )
            let outputSidecarURL = ProvenanceRecorder.fileSidecarURL(
                for: outputURL
            )
            let rootProvenanceURL = publicationRoot.appendingPathComponent(
                ProvenanceRecorder.provenanceFilename
            )
            let provenanceDirectoryURL = publicationRoot.appendingPathComponent(
                ProvenanceWriter.bundleProvenanceDirectoryName,
                isDirectory: true
            )
            let rollupURL = provenanceDirectoryURL.appendingPathComponent(
                ProvenanceWriter.bundleRollupFilename
            )
            let focusedSidecarURL = try XCTUnwrap(
                ProvenanceWriter.bundleOutputSidecarURL(
                    for: outputURL,
                    inBundle: publicationRoot
                )
            )
            let failureURL: URL
            switch failureTarget {
            case .root:
                failureURL = rootProvenanceURL
            case .bundleRollup:
                failureURL = rollupURL
            case .focusedBundleSidecar:
                failureURL = focusedSidecarURL
            case .outputSidecar:
                failureURL = outputSidecarURL
            }
            let priorOutput = Data("prior workbook".utf8)
            let priorSidecar = Data("prior output provenance".utf8)
            let priorRoot = Data("prior root provenance".utf8)
            try priorOutput.write(to: outputURL)
            try priorSidecar.write(to: outputSidecarURL)
            try priorRoot.write(to: rootProvenanceURL)
            let command = try GenotypeExportSubcommand.parse([
                "--bundle", fixture.path,
                "--export-format", "xlsx",
                "--output", outputURL.path,
                "--force",
            ])

            do {
                try await command.runReturningResolvedColumns(
                    afterProvenanceArtifactPublication: { mutation in
                        guard mutation.kind == .provenanceDocumentWritten,
                              mutation.url.standardizedFileURL
                                == failureURL.standardizedFileURL else {
                            return
                        }
                        throw NSError(
                            domain: "GenotypeExportSubcommandTests",
                            code: 97,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Injected failure after \(failureTarget.rawValue) provenance mutation",
                            ]
                        )
                    }
                )
                XCTFail("expected provenance artifact failure")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(
                        "Injected failure after \(failureTarget.rawValue) provenance mutation"
                    )
                )
            }

            XCTAssertEqual(try Data(contentsOf: outputURL), priorOutput)
            XCTAssertEqual(
                try Data(contentsOf: outputSidecarURL),
                priorSidecar
            )
            XCTAssertEqual(
                try Data(contentsOf: rootProvenanceURL),
                priorRoot
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: provenanceDirectoryURL.path
                ),
                "transaction-owned provenance tree must roll back after \(failureTarget.rawValue)"
            )
        }
    }

    func testRollbackRestoresRemovedStaleSigningArtifacts()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "genotype-export-signing-removal-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("existing.xlsx")
        let rootProvenanceURL = root.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(
            for: rootProvenanceURL
        )
        let publicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(
            for: rootProvenanceURL
        )
        let priorOutput = Data("prior workbook".utf8)
        let priorRoot = Data("prior root provenance".utf8)
        let priorSignature = Data("prior signature".utf8)
        let priorPublicKey = Data("prior public key".utf8)
        try priorOutput.write(to: outputURL)
        try priorRoot.write(to: rootProvenanceURL)
        try priorSignature.write(to: signatureURL)
        try priorPublicKey.write(to: publicKeyURL)
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--force",
        ])

        do {
            try await command.runReturningResolvedColumns(
                afterProvenanceArtifactPublication: { mutation in
                    guard mutation.kind == .artifactRemoved,
                          mutation.affectedURLs.contains(
                            signatureURL
                          ) else {
                        return
                    }
                    throw NSError(
                        domain: "GenotypeExportSubcommandTests",
                        code: 101,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Injected failure after signing artifact removal",
                        ]
                    )
                }
            )
            XCTFail("expected signing artifact removal failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Injected failure after signing artifact removal"
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), priorOutput)
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), priorRoot)
        XCTAssertEqual(try Data(contentsOf: signatureURL), priorSignature)
        XCTAssertEqual(try Data(contentsOf: publicKeyURL), priorPublicKey)
    }

    func testRollbackDoesNotDeleteWriterArrivingAfterAtomicDetachment()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-detach-race-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("shared.xlsx")
        let outputSidecarURL = ProvenanceRecorder.fileSidecarURL(
            for: outputURL
        )
        let rootProvenanceURL = root.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let priorOutput = Data("prior workbook".utf8)
        let priorSidecar = Data("prior sidecar".utf8)
        let priorRoot = Data("prior root".utf8)
        let lateExternalOutput = Data("late external workbook".utf8)
        try priorOutput.write(to: outputURL)
        try priorSidecar.write(to: outputSidecarURL)
        try priorRoot.write(to: rootProvenanceURL)
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
            "--force",
        ])
        var externalWriterFired = false

        do {
            try await command.runReturningResolvedColumns(
                beforeProvenancePublication: {
                    throw NSError(
                        domain: "GenotypeExportSubcommandTests",
                        code: 100,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Injected pre-provenance failure",
                        ]
                    )
                },
                afterRollbackArtifactDetached: { detachedOriginalURL in
                    guard detachedOriginalURL.standardizedFileURL
                        == outputURL.standardizedFileURL,
                        !externalWriterFired else {
                        return
                    }
                    externalWriterFired = true
                    try lateExternalOutput.write(
                        to: outputURL,
                        options: .atomic
                    )
                }
            )
            XCTFail("expected injected pre-provenance failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Injected pre-provenance failure"
                )
            )
        }

        XCTAssertTrue(externalWriterFired)
        XCTAssertEqual(
            try Data(contentsOf: outputURL),
            lateExternalOutput,
            "exclusive restore must not replace a writer that arrives after detachment"
        )
        XCTAssertEqual(try Data(contentsOf: outputSidecarURL), priorSidecar)
        XCTAssertEqual(try Data(contentsOf: rootProvenanceURL), priorRoot)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        )
        XCTAssertFalse(
            names.contains {
                $0.contains(".provenance-rollback-")
                    || $0.contains(".provenance-restore-")
            }
        )
    }

    func testExportWithoutForcePreservesOutputCreatedDuringRendering()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-late-output-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputURL = root.appendingPathComponent("late.xlsx")
        let lateBytes = Data("created by another actor".utf8)
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputURL.path,
        ])

        do {
            try await command.runReturningResolvedColumns(
                beforeOutputPublication: {
                    try lateBytes.write(to: outputURL, options: .atomic)
                }
            )
            XCTFail("expected exclusive publication to reject late output")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Output file already exists"
                ),
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), lateBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathExtension(
                    "lungfish-provenance.json"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ProvenanceRecorder.provenanceFilename
                ).path
            )
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.contains("export-staging") })
    }

    func testConcurrentExportsSerializeSharedRootProvenanceRollback()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-concurrent-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fixture = try makeGenotypeBundleFixture(in: root)
        let outputA = root.appendingPathComponent("export-a.xlsx")
        let outputB = root.appendingPathComponent("export-b.xlsx")
        let rootProvenanceURL = root.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let commandA = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputA.path,
        ])
        let commandB = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", outputB.path,
        ])

        let aReachedProvenance = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let bReadyToPublish = DispatchSemaphore(value: 0)
        let allowBPublicationAttempt = DispatchSemaphore(value: 0)
        let bReachedProvenance = DispatchSemaphore(value: 0)
        let releaseBFailure = DispatchSemaphore(value: 0)
        defer {
            releaseA.signal()
            allowBPublicationAttempt.signal()
            releaseBFailure.signal()
        }

        let taskA = Task.detached {
            try await commandA.runReturningResolvedColumns(
                beforeProvenancePublication: {
                    aReachedProvenance.signal()
                    guard releaseA.wait(timeout: .now() + 10) == .success else {
                        throw NSError(
                            domain: "GenotypeExportSubcommandTests",
                            code: 92,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Timed out releasing export A",
                            ]
                        )
                    }
                }
            )
        }
        XCTAssertEqual(
            aReachedProvenance.wait(timeout: .now() + 10),
            .success
        )

        let taskB = Task.detached {
            try await commandB.runReturningResolvedColumns(
                beforeOutputPublication: {
                    bReadyToPublish.signal()
                    guard allowBPublicationAttempt.wait(
                        timeout: .now() + 10
                    ) == .success else {
                        throw NSError(
                            domain: "GenotypeExportSubcommandTests",
                            code: 93,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Timed out starting export B publication",
                            ]
                        )
                    }
                },
                beforeProvenancePublication: {
                    bReachedProvenance.signal()
                    guard releaseBFailure.wait(timeout: .now() + 10)
                        == .success
                    else {
                        throw NSError(
                            domain: "GenotypeExportSubcommandTests",
                            code: 94,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Timed out releasing export B",
                            ]
                        )
                    }
                    throw NSError(
                        domain: "GenotypeExportSubcommandTests",
                        code: 95,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Injected concurrent provenance failure",
                        ]
                    )
                }
            )
        }

        XCTAssertEqual(
            bReadyToPublish.wait(timeout: .now() + 10),
            .success
        )
        allowBPublicationAttempt.signal()
        XCTAssertEqual(
            bReachedProvenance.wait(timeout: .now() + 0.25),
            .timedOut,
            "export B must not enter the shared publication transaction while export A holds it"
        )
        releaseA.signal()
        _ = try await taskA.value
        XCTAssertEqual(
            bReachedProvenance.wait(timeout: .now() + 10),
            .success
        )
        let provenanceAfterA = try Data(contentsOf: rootProvenanceURL)
        let outputASidecar = outputA.appendingPathExtension(
            "lungfish-provenance.json"
        )
        let sidecarAfterA = try Data(contentsOf: outputASidecar)

        releaseBFailure.signal()
        do {
            _ = try await taskB.value
            XCTFail("expected injected export B provenance failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Injected concurrent provenance failure"
                )
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputB.path))
        XCTAssertEqual(
            try Data(contentsOf: rootProvenanceURL),
            provenanceAfterA,
            "export B rollback must preserve export A's committed root provenance"
        )
        XCTAssertEqual(
            try Data(contentsOf: outputASidecar),
            sidecarAfterA,
            "export B rollback must preserve export A's committed sidecar"
        )
    }

    // MARK: - Projection filters visible samples

    func testGenotypeExportProjectionFiltersToVisibleSamples() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)

        // The fixture has three samples (S1, S2, S3). The GUI projection
        // shows only S1 and S2 with the analyst-visible cells/colors. The
        // produced workbook's sample columns must reproduce that view.
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2", "S3"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    locus: "MHC-A",
                    stableClusterID: "cluster-filtered",
                    cells: ["M1A", "M2A"],
                    rowColorHex: nil
                ),
                GenotypeViewProjectionRow(
                    label: "MHC-A H2",
                    cells: ["M3A", "-"],
                    rowColorHex: nil
                ),
            ],
            cellColorMode: "budde2010"
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)

        let out = root.appendingPathComponent("view.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--view-projection", projectionURL.path,
            "--sample", "S1",
            "--sample", "S2",
            "--force",
        ])
        let resolved = try await cmd.runReturningResolvedColumns()
        XCTAssertEqual(resolved, ["S1", "S2"], "expected only the projection's visible sample columns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let sheet = try unzipEntry("xl/worksheets/sheet1.xml", from: out)
        XCTAssertTrue(sheet.contains("cluster-filtered"))
    }

    func testAnnotationBearingProjectionExportEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)

        let projection = GenotypeViewProjection(
            lens: "summary.matrix",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "01_M1A_A1_063",
                    locus: "MHC-A",
                    cells: ["39", "20"]
                ),
                GenotypeViewProjectionRow(
                    label: "01_M1A_A1_063",
                    locus: "MHC-B",
                    cells: ["", "11"]
                )
            ],
            cellColorMode: "nativeAnnotations"
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)

        let out = root.appendingPathComponent("view.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--view-projection", projectionURL.path,
            "--sample", "S1",
            "--sample", "S2",
            "--force",
        ])
        _ = try await cmd.runReturningResolvedColumns()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet2.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId2""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet2.xml""#))
        let viewSheetXML = try unzipEntry("xl/worksheets/sheet1.xml", from: out)
        XCTAssertTrue(viewSheetXML.contains("<t>Locus</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>Row</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>MHC-A</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>MHC-B</t>"))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet2.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("<t>Stable Cluster ID</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Is Bold</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Bold Override</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Is Italic</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Italic Override</t>"))
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("cluster-a"))
        XCTAssertTrue(annotationSheetXML.contains("cluster-b"))
        XCTAssertTrue(annotationSheetXML.contains("Cluster A collision comment."))
        XCTAssertTrue(annotationSheetXML.contains("Cluster B collision comment."))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))
        let annotationRows = annotationSheetXML.components(separatedBy: "<row").dropFirst()
        XCTAssertTrue(annotationRows.contains { $0.contains("cluster-a") && $0.contains("#111111") })
        XCTAssertTrue(annotationRows.contains { $0.contains("cluster-b") && $0.contains("#222222") })
        XCTAssertTrue(annotationRows.contains {
            $0.contains("cluster-a") && $0.contains("Cluster A collision comment.")
        })
        XCTAssertTrue(annotationRows.contains {
            $0.contains("cluster-b") && $0.contains("Cluster B collision comment.")
        })

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        let inputDescriptors = env.files + env.steps.flatMap(\.inputs)
        let inputPaths = Set(inputDescriptors.map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "annotation-bearing exports must record the stable annotations.json sidecar as an input"
        )
        for requiredURL in [projectionURL, sidecarURL] {
            let descriptor = try XCTUnwrap(inputDescriptors.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == requiredURL.standardizedFileURL
            })
            XCTAssertNotNil(descriptor.checksumSHA256)
            XCTAssertGreaterThan(descriptor.fileSize ?? 0, 0)
        }
        XCTAssertEqual(env.argv, [
            CLICommandIdentity.executableName,
            "genotype",
            "export",
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--sample", "S1",
            "--sample", "S2",
            "--view-projection", projectionURL.path,
            "--annotations", sidecarURL.path,
            "--force",
        ])
        XCTAssertEqual(env.options.explicit["bundle"], .file(fixture))
        XCTAssertEqual(env.options.explicit["output"], .file(out))
        XCTAssertEqual(env.options.explicit["viewProjection"], .file(projectionURL))
        XCTAssertEqual(env.options.explicit["annotations"], .file(sidecarURL))
        XCTAssertEqual(env.options.explicit["exportFormat"], .string("xlsx"))
        XCTAssertEqual(env.options.explicit["samples"], .array([.string("S1"), .string("S2")]))
        XCTAssertEqual(env.options.explicit["force"], .boolean(true))
        XCTAssertEqual(env.options.defaults["exportFormat"], .string("xlsx"))
        XCTAssertEqual(env.options.defaults["samples"], .array([]))
        XCTAssertEqual(env.options.defaults["force"], .boolean(false))
        XCTAssertEqual(env.options.resolvedDefaults["exportFormat"], .string("xlsx"))
        XCTAssertEqual(
            env.options.resolvedDefaults["samples"],
            .array([.string("S1"), .string("S2")])
        )
        XCTAssertEqual(env.options.resolvedDefaults["force"], .boolean(true))
        XCTAssertEqual(env.options.resolvedDefaults["annotations"], .file(sidecarURL))
        XCTAssertEqual(env.options.resolvedDefaults["viewProjection"], .file(projectionURL))
    }

    func testFullMatrixExportEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-full-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)
        let out = root.appendingPathComponent("matrix.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--force",
        ])
        try await cmd.run()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet5.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId6""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet5.xml""#))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet5.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        let inputPaths = Set(env.steps.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "full matrix exports must record the stable annotations.json sidecar as an input"
        )
    }

    func testExportXlsxEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-xlsx-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)
        let out = root.appendingPathComponent("legacy-matrix.xlsx")
        let cmd = try GenotypeExportXlsxSubcommand.parse([
            "--bundle", fixture.path,
            "--output", out.path,
        ])
        try await cmd.run()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet5.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId6""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet5.xml""#))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet5.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        XCTAssertEqual(env.workflowName, "genotype.export.xlsx")
        let inputPaths = Set(env.steps.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "export-xlsx must record the stable annotations.json sidecar as an input"
        )
    }

    // MARK: - Writer-level projection rendering

    func testWorkbookWriterRendersProjectionSampleColumns() throws {
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    cells: ["M1A", "M2A"],
                    rowColorHex: nil
                )
            ],
            cellColorMode: "budde2010"
        )
        let columns = GenotypeXlsxWorkbookWriter.resolvedSampleColumns(for: projection)
        XCTAssertEqual(columns, ["S1", "S2"])
    }

    func testProjectionWorkbookAppliesExactReviewsAndNativeScopedNotes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-semantic-ooxml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputURL = root.appendingPathComponent("semantic.xlsx")
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1", "S2", "S3"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "Collision_nov",
                    locus: "MHC-A",
                    stableClusterID: "cluster-a",
                    cells: ["42", "", ""],
                    cellColorsHex: ["#FFF2CC", nil, nil]
                ),
                GenotypeViewProjectionRow(
                    label: "Collision_nov",
                    locus: "MHC-A",
                    stableClusterID: "cluster-b",
                    cells: ["17", "-", "0"],
                    cellColorsHex: ["#D9EAD3", nil, nil]
                ),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S1",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "Analyst A",
                timestamp: "2026-07-24T01:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S2",
                    stableClusterID: "cluster-b"
                ),
                disposition: .falseNegative,
                author: "Analyst B",
                timestamp: "2026-07-24T01:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S3",
                    stableClusterID: "cluster-b"
                ),
                disposition: .falseNegative,
                author: "Analyst B",
                timestamp: "2026-07-24T01:01:01Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S2",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "Imported",
                timestamp: "2026-07-24T01:01:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A", genotype: "Collision_nov", stableClusterID: "cluster-a"),
                body: "Allele context",
                author: "Row Author",
                timestamp: "2026-07-24T02:00:00Z"
            ),
            .init(
                target: .column(sample: "S1"),
                body: "Sample context",
                author: "Column Author",
                timestamp: "2026-07-24T02:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S1",
                    stableClusterID: "cluster-a"
                ),
                body: "Cell context",
                author: "Cell Author",
                timestamp: "2026-07-24T02:02:00Z"
            ),
        ]
        sidecar.auditLog = [
            .init(
                action: "setMatrixReview",
                sample: "cell|locus=MHC-A|genotype=Collision_nov|sample=S1|stableClusterID=cluster-a",
                locus: "MHC-A",
                slot: nil,
                before: nil,
                after: "falsePositive",
                color: nil,
                reason: "passedUniqueReads > 0",
                rationale: nil,
                author: "Analyst A",
                timestamp: "2026-07-24T01:00:00Z"
            ),
        ]

        let catalog = try GenotypeReviewableRowCatalog(
            samples: ["S1", "S2", "S3"],
            rows: [
                .init(
                    kind: .candidate,
                    callID: "candidate:MHC-A:cluster-a",
                    displayName: "Collision_nov",
                    locus: "MHC-A",
                    stableID: "cluster-a",
                    section: "candidate",
                    sortKey: "MHC-A|Collision_nov|cluster-a",
                    supportBySample: ["S1": 42, "S2": 0, "S3": 0]
                ),
                .init(
                    kind: .candidate,
                    callID: "candidate:MHC-A:cluster-b",
                    displayName: "Collision_nov",
                    locus: "MHC-A",
                    stableID: "cluster-b",
                    section: "candidate",
                    sortKey: "MHC-A|Collision_nov|cluster-b",
                    supportBySample: ["S1": 17, "S2": 0, "S3": 0]
                ),
            ]
        ).validated()
        try GenotypeXlsxWorkbookWriter().writeViewProjection(
            projection,
            to: outputURL,
            annotations: sidecar,
            reviewableRowCatalog: catalog
        )

        let sheet = try unzipEntry("xl/worksheets/sheet1.xml", from: outputURL)
        XCTAssertTrue(sheet.contains("<t>Stable Cluster ID</t>"))
        XCTAssertTrue(sheet.contains("<t>cluster-a</t>"))
        XCTAssertTrue(sheet.contains("<t>cluster-b</t>"))
        XCTAssertTrue(sheet.contains("<t>[42]</t>"))
        XCTAssertTrue(sheet.contains(#"r="D2""#), "cluster-a / S1 must be the false-positive cell")
        XCTAssertTrue(sheet.contains(#"r="E3""#), "empty false-negative cells must be emitted")
        XCTAssertTrue(sheet.contains(#"r="F3""#), "explicit-zero false-negative cells must be emitted")
        XCTAssertTrue(sheet.contains("<t>FN</t>"), "false negatives must use a literal portable marker")
        XCTAssertFalse(sheet.contains("<t>-</t>"), "absent false-negative values must remain empty")
        XCTAssertFalse(sheet.contains("<t>[]</t>"), "invalid false-positive reviews must not format empty cells")
        XCTAssertTrue(sheet.contains("legacyDrawing"))

        let styles = try unzipEntry("xl/styles.xml", from: outputURL)
        XCTAssertTrue(styles.contains("<i/>"))
        XCTAssertTrue(styles.contains("FF767676"))
        XCTAssertTrue(styles.contains(#"<left style="mediumDashed""#))
        XCTAssertTrue(styles.contains(#"<right style="mediumDashed""#))
        XCTAssertTrue(styles.contains(#"<top style="mediumDashed""#))
        XCTAssertTrue(styles.contains(#"<bottom style="mediumDashed""#))
        XCTAssertTrue(styles.contains("FFC65911"))
        XCTAssertTrue(styles.contains("FFFFF2CC"))
        XCTAssertTrue(styles.contains("FF7F6000"))

        let comments = try unzipEntry("xl/comments1.xml", from: outputURL)
        XCTAssertTrue(comments.contains("<authors>"))
        XCTAssertTrue(comments.contains("Row Author"))
        XCTAssertTrue(comments.contains("Column Author"))
        XCTAssertTrue(comments.contains("Cell Author"))
        let combinedStart = try XCTUnwrap(comments.range(of: #"ref="D2""#)).lowerBound
        let combinedEnd = try XCTUnwrap(
            comments.range(of: "</comment>", range: combinedStart..<comments.endIndex)
        ).upperBound
        let combinedComment = String(comments[combinedStart..<combinedEnd])
        let alleleRange = try XCTUnwrap(combinedComment.range(of: "Allele Row"))
        let sampleRange = try XCTUnwrap(combinedComment.range(of: "Sample Column"))
        let cellRange = try XCTUnwrap(combinedComment.range(of: "Cell"))
        XCTAssertLessThan(alleleRange.lowerBound, sampleRange.lowerBound)
        XCTAssertLessThan(sampleRange.lowerBound, cellRange.lowerBound)
        XCTAssertEqual(comments.components(separatedBy: #"ref="D2""#).count - 1, 1)

        let vml = try unzipEntry("xl/drawings/commentsDrawing1.vml", from: outputURL)
        XCTAssertTrue(vml.contains("<x:Row>1</x:Row>"))
        XCTAssertTrue(vml.contains("<x:Column>3</x:Column>"))
        let sheetRels = try unzipEntry("xl/worksheets/_rels/sheet1.xml.rels", from: outputURL)
        XCTAssertTrue(sheetRels.contains("relationships/comments"))
        XCTAssertTrue(sheetRels.contains("relationships/vmlDrawing"))
        let contentTypes = try unzipEntry("[Content_Types].xml", from: outputURL)
        XCTAssertTrue(contentTypes.contains("/xl/comments1.xml"))
        XCTAssertTrue(contentTypes.contains(#"Extension="vml""#))

        let annotationSheet = try unzipEntry("xl/worksheets/sheet2.xml", from: outputURL)
        XCTAssertTrue(annotationSheet.contains("<t>Disposition</t>"))
        XCTAssertTrue(annotationSheet.contains("<t>Validation Status</t>"))
        XCTAssertTrue(annotationSheet.contains("falsePositive"))
        XCTAssertTrue(annotationSheet.contains("falseNegative"))
        XCTAssertTrue(annotationSheet.contains("valid"))
        XCTAssertTrue(annotationSheet.contains("invalid"))
        XCTAssertTrue(annotationSheet.contains("passedUniqueReads &gt; 0"))
        let auditSheet = try unzipEntry("xl/worksheets/sheet3.xml", from: outputURL)
        XCTAssertTrue(auditSheet.contains("setMatrixReview"))
        XCTAssertTrue(auditSheet.contains("stableClusterID=cluster-a"))
        XCTAssertTrue(auditSheet.contains("matrixReviewExportValidation"))
        XCTAssertTrue(
            auditSheet.contains("cell S2 MHC-A Collision_nov [cluster-a]")
        )
        XCTAssertTrue(auditSheet.contains(">invalid<"))
        XCTAssertTrue(auditSheet.contains("False-positive reviews require passedUniqueReads &gt; 0."))

        let csv = GenotypeXlsxWorkbookWriter.renderDelimited(projection, separator: ",")
        XCTAssertTrue(csv.contains("MHC-A,Collision_nov,42,"))
        XCTAssertFalse(csv.contains("[42]"), "semantic Excel typography must not alter delimited values")
    }

    func testProjectionWorkbookSynthesizesAuthoritativeFalseNegativeRowWithPortableStyleAndComments()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-native-fn-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let outputURL = root.appendingPathComponent("native-fn.xlsx")
        let clearedURL = root.appendingPathComponent("native-cleared.xlsx")
        let formulaLikeLabel = "=Mafa-A1*999:99"
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1", "S2"],
            rows: [
                .init(
                    label: "Mafa-B*001:01",
                    locus: "MHC-B",
                    cells: ["12", "7"]
                ),
            ]
        )
        let catalog = try GenotypeReviewableRowCatalog(
            samples: ["S1", "S2"],
            rows: [
                .init(
                    kind: .reference,
                    callID: "reference:MHC-A:formula-like",
                    displayName: formulaLikeLabel,
                    locus: "MHC-A",
                    stableID: nil,
                    section: "reference",
                    sortKey: "MHC-A|formula-like",
                    supportBySample: ["S1": 0, "S2": 0]
                ),
            ]
        ).validated()
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel,
                    sample: "S1"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel,
                    sample: "S2"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:01:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .row(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel
                ),
                body: "Allele context",
                author: "Row Author",
                timestamp: "2026-07-27T02:00:00Z"
            ),
            .init(
                target: .column(sample: "S1"),
                body: "Sample context",
                author: "Column Author",
                timestamp: "2026-07-27T02:01:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: formulaLikeLabel,
                    sample: "S1"
                ),
                body: "Cell context",
                author: "Cell Author",
                timestamp: "2026-07-27T02:02:00Z"
            ),
        ]

        let report = try GenotypeXlsxWorkbookWriter().writeViewProjection(
            projection,
            to: outputURL,
            annotations: sidecar,
            reviewableRowCatalog: catalog
        )

        XCTAssertEqual(report.adapterVersion, "native-view-projection-v1")
        XCTAssertEqual(report.synthesizedRows.count, 1)
        XCTAssertEqual(
            report.synthesizedRows.first?.identity.callID,
            "reference:MHC-A:formula-like"
        )
        XCTAssertEqual(report.synthesizedRows.first?.cells, ["D4", "E4"])
        XCTAssertEqual(report.targetCells.count, 2)
        XCTAssertEqual(report.targetCells.first?.cell, "D4")
        XCTAssertEqual(report.targetCells.first?.status, "valid")
        XCTAssertEqual(
            report.targetCells.first?.presentationPrecedence,
            "false-negative-over-viewport-style"
        )

        let sheet = try unzipEntry("xl/worksheets/sheet1.xml", from: outputURL)
        XCTAssertEqual(
            sheet.components(separatedBy: "Analyst annotation-only rows").count - 1,
            1
        )
        XCTAssertEqual(
            sheet.components(separatedBy: "<t>\(formulaLikeLabel)</t>").count - 1,
            1
        )
        XCTAssertFalse(sheet.contains("<f>"))
        XCTAssertTrue(sheet.contains(#"<c r="D4""#))
        XCTAssertTrue(sheet.contains(#"<c r="E4""#))
        XCTAssertEqual(
            sheet.components(separatedBy: "<t>FN</t>").count - 1,
            2
        )
        let styles = try unzipEntry("xl/styles.xml", from: outputURL)
        for token in [
            #"style="mediumDashed""#,
            "FFC65911",
            "FFFFF2CC",
            "FF7F6000",
        ] {
            XCTAssertTrue(styles.contains(token), "missing native FN style token \(token)")
        }
        XCTAssertTrue(
            styles.contains(
                #"<xf numFmtId="0" fontId="3" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>"#
            ),
            "the FN cell style must bind the portable font, fill, and border together"
        )
        let comments = try unzipEntry("xl/comments1.xml", from: outputURL)
        let combinedStart = try XCTUnwrap(
            comments.range(of: #"ref="D4""#)
        ).lowerBound
        let combinedEnd = try XCTUnwrap(
            comments.range(
                of: "</comment>",
                range: combinedStart..<comments.endIndex
            )
        ).upperBound
        let combined = String(comments[combinedStart..<combinedEnd])
        XCTAssertTrue(combined.contains("Allele Row"))
        XCTAssertTrue(combined.contains("Sample Column"))
        XCTAssertTrue(combined.contains("Cell"))

        sidecar.matrixReviews = []
        try GenotypeXlsxWorkbookWriter().writeViewProjection(
            projection,
            to: clearedURL,
            annotations: sidecar,
            reviewableRowCatalog: catalog
        )
        let clearedSheet = try unzipEntry(
            "xl/worksheets/sheet1.xml",
            from: clearedURL
        )
        XCTAssertFalse(clearedSheet.contains("Analyst annotation-only rows"))
        XCTAssertFalse(clearedSheet.contains("<t>FN</t>"))
    }

    func testProjectionWorkbookRequiresCatalogAuthorityForFalseNegatives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "genotype-export-native-fn-no-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: [
                .init(
                    label: "Mafa-A1*001:01",
                    locus: "MHC-A",
                    cells: [""]
                ),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mafa-A1*001:01",
                    sample: "S1"
                ),
                disposition: .falseNegative,
                author: "Reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        let outputURL = root.appendingPathComponent("must-not-exist.xlsx")

        XCTAssertThrowsError(
            try GenotypeXlsxWorkbookWriter().writeViewProjection(
                projection,
                to: outputURL,
                annotations: sidecar
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testProjectionWorkbookFailsClosedForConflictingDuplicateImportedReviews() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-conflicting-reviews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "Collision_nov",
                    locus: "MHC-A",
                    stableClusterID: "cluster-a",
                    cells: ["42"]
                )
            ]
        )
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "Collision_nov",
            sample: "S1",
            stableClusterID: "cluster-a"
        )
        let falsePositive = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: target,
            disposition: .falsePositive,
            author: "FP Author",
            timestamp: "2026-07-24T03:00:00Z"
        )
        let falseNegative = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: target,
            disposition: .falseNegative,
            author: "FN Author",
            timestamp: "2026-07-24T03:01:00Z"
        )

        for (offset, reviews) in [
            [falsePositive, falseNegative],
            [falseNegative, falsePositive],
        ].enumerated() {
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-24T00:00:00Z"
            )
            sidecar.matrixReviews = reviews
            let outputURL = root.appendingPathComponent("conflict-\(offset).xlsx")

            try GenotypeXlsxWorkbookWriter().writeViewProjection(
                projection,
                to: outputURL,
                annotations: sidecar
            )

            let sheet = try unzipEntry("xl/worksheets/sheet1.xml", from: outputURL)
            XCTAssertTrue(sheet.contains(#"<c r="D2" s="3" t="inlineStr"><is><t>42</t>"#))
            XCTAssertFalse(sheet.contains("[42]"))

            for entry in ["xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml"] {
                let semanticSheet = try unzipEntry(entry, from: outputURL)
                XCTAssertEqual(
                    semanticSheet.components(separatedBy: ">invalid<").count - 1,
                    2
                )
                XCTAssertEqual(
                    semanticSheet.components(
                        separatedBy: "Conflicting duplicate review records target the same projection cell."
                    ).count - 1,
                    2
                )
                XCTAssertTrue(semanticSheet.contains("falsePositive"))
                XCTAssertTrue(semanticSheet.contains("falseNegative"))
                XCTAssertTrue(semanticSheet.contains("FP Author"))
                XCTAssertTrue(semanticSheet.contains("FN Author"))
            }
        }
    }

    func testFullMatrixListsExactCellReviewsAsUnappliedInsteadOfHeuristicMatching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-full-unapplied-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputURL = root.appendingPathComponent("matrix.xlsx")
        let matrix = GenotypeXlsxWorkbookWriter.Matrix(
            loci: ["MHC-A"],
            rows: [
                .init(sample: "S1", cells: [.haplotype("M1A", 1), .absent])
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S1",
                    stableClusterID: "cluster-a"
                ),
                disposition: .falsePositive,
                author: "Analyst",
                timestamp: "2026-07-24T01:00:00Z"
            )
        ]

        try GenotypeXlsxWorkbookWriter().writeMatrix(
            to: outputURL,
            matrix: matrix,
            overrides: [],
            audit: [],
            annotations: sidecar
        )

        let matrixSheet = try unzipEntry("xl/worksheets/sheet1.xml", from: outputURL)
        XCTAssertFalse(matrixSheet.contains("[M1A]"))
        let annotations = try unzipEntry("xl/worksheets/sheet5.xml", from: outputURL)
        XCTAssertTrue(annotations.contains("falsePositive"))
        XCTAssertTrue(annotations.contains("unapplied"))
        XCTAssertTrue(annotations.contains("sample-by-haplotype"))
        let audit = try unzipEntry("xl/worksheets/sheet4.xml", from: outputURL)
        XCTAssertTrue(audit.contains("matrixReviewExportValidation"))
        XCTAssertTrue(audit.contains("cell S1 MHC-A Collision_nov [cluster-a]"))
        XCTAssertTrue(audit.contains(">falsePositive<"))
        XCTAssertTrue(audit.contains(">unapplied<"))
        XCTAssertTrue(audit.contains("Analyst"))
        XCTAssertTrue(audit.contains("2026-07-24T01:00:00Z"))
    }

    // MARK: - Fixture

    private func unzipEntry(_ entry: String, from archiveURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let escapedEntry = entry
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        process.arguments = ["-p", archiveURL.path, escapedEntry]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @discardableResult
    private func seedMatrixAnnotations(in bundleURL: URL) throws -> URL {
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        var sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        sidecar.matrixStyles = [
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .cell(locus: "MHC-A", genotype: "01_M1A_A1_063", sample: "S1"),
                style: GenotypeAnnotationSidecar.MatrixStyle(
                    fillColor: "#FFF2CC",
                    textColor: "#C00000",
                    borderColor: "#00AAFF",
                    isBold: true,
                    isItalic: true
                ),
                author: "qa",
                timestamp: "2026-06-30T10:00:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .row(locus: "MHC-B", genotype: "HiddenOnly"),
                style: GenotypeAnnotationSidecar.MatrixStyle(fillColor: "#D9EAD3"),
                author: "qa",
                timestamp: "2026-06-30T10:01:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .row(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    stableClusterID: "cluster-a"
                ),
                style: GenotypeAnnotationSidecar.MatrixStyle(fillColor: "#111111"),
                author: "qa",
                timestamp: "2026-06-30T10:01:01Z"
            ),
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .row(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    stableClusterID: "cluster-b"
                ),
                style: GenotypeAnnotationSidecar.MatrixStyle(fillColor: "#222222"),
                author: "qa",
                timestamp: "2026-06-30T10:01:02Z"
            ),
        ]
        sidecar.matrixComments = [
            GenotypeAnnotationSidecar.MatrixComment(
                target: .cell(locus: "MHC-A", genotype: "01_M1A_A1_063", sample: "S1"),
                body: "Visible cell comment.",
                author: "qa",
                timestamp: "2026-06-30T10:02:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: .row(locus: "MHC-B", genotype: "HiddenOnly"),
                body: "Hidden annotation comment.",
                author: "qa",
                timestamp: "2026-06-30T10:03:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S1",
                    stableClusterID: "cluster-a"
                ),
                body: "Cluster A collision comment.",
                author: "qa",
                timestamp: "2026-06-30T10:03:01Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Collision_nov",
                    sample: "S1",
                    stableClusterID: "cluster-b"
                ),
                body: "Cluster B collision comment.",
                author: "qa",
                timestamp: "2026-06-30T10:03:02Z"
            ),
        ]
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            expectedRevision: snapshot.revision,
            forBundleAt: bundleURL
        )
        return sidecarURL
    }

    /// Builds a minimal `.lungfishgenotype` bundle with three samples
    /// (S1, S2, S3) so projection-driven filtering has something to drop.
    private func overwriteInPlace(_ url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func inode(of url: URL) throws -> UInt64 {
        var information = stat()
        guard url.path.withCString({
            Darwin.lstat($0, &information)
        }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(information.st_ino)
    }

    private func makeGenotypeBundleFixture(in root: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("fixture.xlsx")
        let longCSV = bundleURL.appendingPathComponent("fixture.retained-demux-genotypes.csv")
        let sampleCSV = bundleURL.appendingPathComponent("fixture.retained-demux-samples.csv")
        let statsJSON = bundleURL.appendingPathComponent("fixture.retained-demux-stats.json")
        let provenanceJSON = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let haplotypeJSON = bundleURL.appendingPathComponent("haplotype-analysis.json")
        let reviewCatalogURL = bundleURL.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceJSON)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,01_M1A_A1_063,42,39,100,46,46.0,1000,60,6.0
        S1,02_M3A_A2_010,30,30,100,46,46.0,1000,60,6.0
        S2,01_M1A_A1_063,22,20,80,30,37.5,1000,60,6.0
        S3,13_Mafa_DRB1_06,12,12,90,4,4.4,1000,60,6.0
        """.write(to: longCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,72,69,100,46.0,1000,6.0
        S2,22,20,80,37.5,1000,6.0
        S3,12,12,90,4.4,1000,6.0
        """.write(to: sampleCSV, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1000,
          "totalAlignments": 120,
          "passedAlignments": 84,
          "retainedUniqueReads": 60,
          "retainedUniquePercentOfTotalReads": 6.0,
          "assignedUniqueRetainedReads": 53,
          "unassignedUniqueRetainedReads": 7
        }
        """.write(to: statsJSON, atomically: true, encoding: .utf8)

        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-05-22T10:00:00Z",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S1",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["01_M1A_A1_063", "02_M3A_A2_010"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S2",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1A_A1_063"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S3",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["13_Mafa_DRB1_06"]
                        )
                    ]
                ),
            ]
        )
        let analysisEncoder = JSONEncoder()
        analysisEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try analysisEncoder.encode(analysis).write(to: haplotypeJSON)
        try FileManager.default.createDirectory(
            at: reviewCatalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let reviewCatalog = try GenotypeReviewableRowCatalog(
            samples: ["S1", "S2", "S3"],
            rows: [
                .init(
                    kind: .reference,
                    callID: "reference:MHC-A:formula-like",
                    displayName: "=Mafa-A1*999:99",
                    locus: "MHC-A",
                    stableID: nil,
                    section: "reference",
                    sortKey: "MHC-A|formula-like",
                    supportBySample: ["S1": 0, "S2": 0, "S3": 0]
                ),
            ]
        ).validated()
        try reviewCatalog.encoded().write(to: reviewCatalogURL)
        let reviewCatalogReference = ONTMHCArtifactReference(
            path: "artifacts/review/reviewable-row-catalog.json",
            sha256: try ProvenanceFileHasher.sha256(of: reviewCatalogURL),
            sizeBytes: Int64(
                try ProvenanceFileHasher.fileSize(of: reviewCatalogURL)
            )
        )

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: longCSV.lastPathComponent,
            sampleSummaryCSVPath: sampleCSV.lastPathComponent,
            statsJSONPath: statsJSON.lastPathComponent,
            provenancePath: provenanceJSON.lastPathComponent,
            haplotypeAnalysisPath: haplotypeJSON.lastPathComponent,
            haplotypeDefinitionSetID: "mauritian-cynomolgus-macaques",
            createdAt: "2026-05-22T10:00:00Z",
            reviewableRowCatalog: reviewCatalogReference
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        return bundleURL
    }
}
