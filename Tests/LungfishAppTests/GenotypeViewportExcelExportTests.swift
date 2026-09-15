import LungfishKit
import CryptoKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

final class GenotypeViewportExcelExportTests: XCTestCase {
    @MainActor
    func testDisposableRealBundleControllerAndProductionExcelParity() async throws {
        try await GenotypeThreeSheetCohortAcceptance.run()
    }

    @MainActor
    func testReviewedActiveAnalysisReachesProductionFilteredWorkbookAndProvenance()
        async throws
    {
        let python = try XCTUnwrap(managedOpenpyxlPythonURL())
        let resolvedCLI = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            ),
            "Inject the swiftbuild lungfish-cli path or build it beside the test bundle"
        )
        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        XCTAssertEqual(setenv("LUNGFISH_CLI_PATH", resolvedCLI.path, 1), 0)
        defer {
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "reviewed.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"analysis":"scientific-export-test"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "reviewed-export-definition",
            assayID: "MHC-exon2-miSeq",
            displayName: "Reviewed export definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                .init(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        .init(
                            name: "M1A",
                            diagnosticAlleles: ["01_M1_A_marker"],
                            minimumMatches: 1
                        ),
                        .init(
                            name: "M2A",
                            diagnosticAlleles: ["02_M2_A_marker"],
                            minimumMatches: 1
                        ),
                    ]
                ),
            ]
        )
        let inputsURL = bundleURL
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inputsURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(definition).write(
            to: inputsURL.appendingPathComponent("haplotype-definition.json")
        )
        let retained = GenotypeTestFixtures.makeCall(
            sample: "AnimalA",
            genotype: "01_M1_A_marker",
            reads: 100,
            retainedReads: 103
        )
        let excluded = GenotypeTestFixtures.makeCall(
            sample: "AnimalA",
            genotype: "02_M2_A_marker",
            reads: 3,
            retainedReads: 103
        )
        let rawCalls = [retained, excluded]
        let initiallyInferred = GenotypeHaplotypeAnalyzer.analyze(
            calls: rawCalls,
            definitionSet: definition
        )
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: initiallyInferred.assayID,
            definitionSetID: initiallyInferred.definitionSetID,
            definitionSetName: initiallyInferred.definitionSetName,
            speciesName: initiallyInferred.speciesName,
            generatedAt: initiallyInferred.generatedAt,
            analysisRevisionID: "persisted-before-review",
            source: initiallyInferred.source,
            samples: initiallyInferred.samples
        )
        let result = GenotypeTestFixtures.makeResult(
            bundleURL: bundleURL,
            samples: [
                .init(
                    sample: "AnimalA",
                    passedAlignments: 103,
                    passedUniqueReads: 103,
                    sampleTotalReads: 103,
                    sampleUniqueRetainedPercent: 100,
                    calls: rawCalls
                ),
            ],
            calls: rawCalls,
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definition.id
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(
            summaryViewMode: .matrix,
            hideLowSupport: true,
            minimumSupportPercent: 7.5,
            supportDenominator: .sampleRetained,
            matrixMinimumPercent: 0,
            matrixPercentDenominator: .viewedLocus
        ))
        let reviewTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: excluded.genotype,
            sample: "AnimalA"
        )
        controller.applyMatrixReview(.init(
            targets: [reviewTarget],
            intent: .set(.falsePositive)
        ))

        let snapshot = try controller.captureExcelExportSnapshot()
        let frozen = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(snapshot.excelSnapshotData))
        let call = try XCTUnwrap(frozen.calls.first)
        XCTAssertEqual(call.h1.effective, "M1A")
        XCTAssertEqual(call.h2.effective, "M1A")
        XCTAssertEqual(call.h1.pipeline, "M1A")
        XCTAssertEqual(call.h2.pipeline, "-")
        XCTAssertEqual(frozen.filteredMatrix.rows.map(\.target.genotype), [retained.genotype])
        XCTAssertEqual(frozen.allMatrix.rows.map(\.target.genotype), [retained.genotype, excluded.genotype])
        XCTAssertEqual(frozen.sourceRevision["analysisRevisionID"], "", "Transient reviewed analysis cannot claim the persisted revision")
        let outputURL = root.appendingPathComponent("report.xlsx")
        // Later native edits and source deletion cannot change captured calls,
        // evidence, annotations, definition or provenance.
        controller.editMatrixComment(.init(targets: [.column(sample: "AnimalA")], intent: .upsert(body: "Later edit")))
        try FileManager.default.removeItem(at: inputsURL)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let nativeBytes = try Data(contentsOf: annotationURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundleURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleURL.path) }
        let exported = try await GenotypeViewportExportService().exportExcel(snapshot: snapshot, to: outputURL, pythonExecutableURL: python)
        XCTAssertEqual(try Data(contentsOf: annotationURL), nativeBytes)
        let publishedBytes = try Data(contentsOf: outputURL)
        let publishedReceipt = try Data(contentsOf: exported.provenanceURL)
        do {
            _ = try await GenotypeViewportExportService().exportExcel(snapshot: snapshot, to: outputURL,
                pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/false"))
            XCTFail("Failed renderer must reject publication")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: outputURL), publishedBytes)
        XCTAssertEqual(try Data(contentsOf: exported.provenanceURL), publishedReceipt)
        let dumped = try runPython(python, script: Self.dumpScientificFilteredWorkbookScript, arguments: [outputURL.path])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dumped.utf8)) as? [String: Any])
        XCTAssertEqual(payload["sheets"] as? [String], ["Haplotype Calls", "Genotype Matrix - All", "Genotype Matrix - Filtered", "Export Metadata"])
        XCTAssertEqual(payload["call"] as? [String], ["AnimalA", "MHC-A", "M1A", "M1A", "called", "called", "pipeline", "pipeline", "M1A", "-"])
        XCTAssertEqual(payload["matrixRows"] as? [[String]], [[retained.genotype, "MHC-A", "", "100"]])
        XCTAssertEqual(payload["allRows"] as? Int, 2)
        XCTAssertEqual(payload["bands"] as? [[String]], [["M1A", "M1A"], ["M1A", "M1A"]])
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: String])
        XCTAssertEqual(metadata["minimumSupportPercent"], "7.5")
        XCTAssertEqual(metadata["supportDenominator"], "Sample Retained")
        XCTAssertEqual(metadata["matrixMinimumPercent"], "0.0")
        XCTAssertEqual(metadata["matrixPercentDenominator"], "Viewed Locus")
        XCTAssertEqual(payload["formulaCount"] as? Int, 0)

        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.provenanceURL)) as? [String: Any])
        XCTAssertEqual(receipt["workflowName"] as? String, "genotype.export.excel")
        XCTAssertEqual(receipt["toolVersion"] as? String, LungfishAppVersion.short)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        let descriptor = try XCTUnwrap(receipt["output"] as? [String: Any])
        XCTAssertEqual(descriptor["path"] as? String, outputURL.path)
        XCTAssertEqual(descriptor["sha256"] as? String, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(descriptor["sizeBytes"] as? Int, try Data(contentsOf: outputURL).count)
        XCTAssertTrue((receipt["durableReplayArgv"] as? [String])?.contains("--snapshot") == true)
        XCTAssertEqual((receipt["durableReplayArgv"] as? [String])?.first, resolvedCLI.standardizedFileURL.path)
        let stored = try XCTUnwrap(receipt["snapshot"] as? [String: Any])
        let storedURL = URL(fileURLWithPath: try XCTUnwrap(stored["path"] as? String))
        let replay = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: Data(contentsOf: storedURL))
        XCTAssertEqual(replay.sourceRevision["definitionSetID"], definition.id)
        XCTAssertEqual(replay.sourceRevision["analysisRevisionID"], "")
        XCTAssertEqual(replay.calls.first?.h2.effective, "M1A")
        let scientific = try XCTUnwrap(replay.capturedScientificInputs)
        for name in ["result.json", "annotations.json", "analysis.json", "definition.json", "all-projection.json", "filtered-projection.json"] {
            XCTAssertEqual(replay.sourceRevision[name], SHA256.hash(data: try XCTUnwrap(scientific[name])).map { String(format: "%02x", $0) }.joined())
        }
        let capturedSidecar = try GenotypeAnnotationSidecar.decode(XCTUnwrap(scientific["annotations.json"]))
        XCTAssertNil(capturedSidecar.resolvedMatrixComments[.column(sample: "AnimalA")])
        XCTAssertEqual(capturedSidecar.matrixReviews.first?.target, reviewTarget)
    }

    func testExportShellsGenotypeExportCLIWithProjectionAndVisibleSamples() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "barcode05-mhc.lungfishgenotype")
        let outputURL = root.appendingPathComponent("barcode05-mhc-view.xlsx")

        let runner = StubGenotypeExportCLIRunner(writesOutput: true, writesProvenance: true)
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "barcode05-mhc",
            lens: "summary.matrix",
            filters: ["searchText": "MHC-A", "minimumSupportPercent": "1.0"],
            sampleNames: ["AnimalA", "AnimalB"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    stableClusterID: "cluster-viewport-1",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(
                        fillColor: AnnotationColor(red: 0.2, green: 0.4, blue: 0.8)
                    ),
                    cellStyles: [
                        "AnimalA": GenotypeResultHighlightStyle(
                            fillColor: AnnotationColor(red: 0.6, green: 0.8, blue: 1.0)
                        )
                    ]
                )
            ]
        )

        let result = try GenotypeViewportExportService(runner: runner).export(
            snapshot: snapshot,
            format: .csv,
            to: outputURL
        )

        XCTAssertEqual(result.outputURL, outputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        XCTAssertEqual(runner.invocations.count, 1)
        let arguments = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(arguments.prefix(2), ["genotype", "export"])
        XCTAssertEqual(try value(after: "--bundle", in: arguments), sourceBundle.path)
        XCTAssertEqual(try value(after: "--export-format", in: arguments), "csv")
        XCTAssertEqual(try value(after: "--output", in: arguments), outputURL.path)
        XCTAssertEqual(try value(after: "--lens", in: arguments), "summary.matrix")
        XCTAssertEqual(try value(after: "--filter", in: arguments), "MHC-A")
        XCTAssertTrue(arguments.contains("--view-projection"))
        XCTAssertTrue(arguments.contains("--force"))
        let sampleValues = arguments.enumerated().compactMap { index, token -> String? in
            token == "--sample" && arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        XCTAssertEqual(sampleValues, ["AnimalA", "AnimalB"])

        // The projection JSON the service handed the CLI must describe the
        // visible columns with parity rows and #RRGGBB colors.
        let projectionPath = try value(after: "--view-projection", in: arguments)
        let projection = try XCTUnwrap(runner.capturedProjection)
        XCTAssertEqual(projection.lens, "summary.matrix")
        XCTAssertEqual(projection.sampleColumns, ["AnimalA", "AnimalB"])
        XCTAssertEqual(projection.rows.count, 1)
        let projectedRow = try XCTUnwrap(projection.rows.first)
        XCTAssertEqual(projectedRow.label, "01_M1_A_01")
        XCTAssertEqual(projectedRow.locus, "MHC-A")
        XCTAssertEqual(projectedRow.stableClusterID, "cluster-viewport-1")
        XCTAssertEqual(projectedRow.cells.count, projection.sampleColumns.count)
        XCTAssertEqual(projectedRow.cells, ["42", ""])
        let cellColors = try XCTUnwrap(projectedRow.cellColorsHex)
        XCTAssertEqual(cellColors.count, projection.sampleColumns.count)
        XCTAssertEqual(cellColors[0], "#99CCFF")
        XCTAssertEqual(projectedRow.rowColorHex, "#3366CC")
        for hex in cellColors.compactMap({ $0 }) {
            XCTAssertTrue(hex.hasPrefix("#"))
            XCTAssertEqual(hex.dropFirst().count, 6)
        }

        // The projection JSON is part of the replay contract recorded in
        // provenance, so it must survive as a durable export sidecar.
        XCTAssertEqual(
            projectionPath,
            outputURL.standardizedFileURL.appendingPathExtension("view-projection.json").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectionPath))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.workflowName, "lungfish genotype export")
        let inputPaths = Set((envelope.files + envelope.steps.flatMap(\.inputs)).map(\.path))
        XCTAssertTrue(inputPaths.contains(projectionPath))
    }

    func testExportFailsWhenCLIOmitsProvenanceSidecar() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let outputURL = root.appendingPathComponent("export.xlsx")

        let runner = StubGenotypeExportCLIRunner(writesOutput: true, writesProvenance: false)
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ]
        )

        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: snapshot,
                format: .csv,
                to: outputURL
            )
        )
    }

    func testExportRejectsProvenanceStampedByGUIToolName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let outputURL = root.appendingPathComponent("export.xlsx")

        // A runner that writes a sidecar with the OLD fake GUI tool name must
        // be rejected by verifyProvenance.
        let runner = StubGenotypeExportCLIRunner(
            writesOutput: true,
            writesProvenance: true,
            toolName: "Lungfish Genome Explorer"
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ]
        )

        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: snapshot,
                format: .csv,
                to: outputURL
            )
        )
    }

    func testExportPassesAnnotationSidecarAndRequiresItInProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let sidecarURL = sourceBundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z").encoded().write(to: sidecarURL)
        let outputURL = root.appendingPathComponent("export.xlsx")

        let runner = StubGenotypeExportCLIRunner(
            writesOutput: true,
            writesProvenance: true,
            recordsAnnotationInput: true
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ],
            annotationSidecarURL: sidecarURL
        )

        let result = try GenotypeViewportExportService(runner: runner).export(
            snapshot: snapshot,
            format: .csv,
            to: outputURL
        )

        let arguments = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(try value(after: "--annotations", in: arguments), sidecarURL.path)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let inputPaths = Set((envelope.files + envelope.steps.flatMap(\.inputs)).map(\.path))
        XCTAssertTrue(inputPaths.contains(sidecarURL.path))
    }

    func testExportRejectsAnnotationSidecarProvenanceWhenSidecarInputIsMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let sidecarURL = sourceBundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z").encoded().write(to: sidecarURL)
        let outputURL = root.appendingPathComponent("export.xlsx")

        let runner = StubGenotypeExportCLIRunner(
            writesOutput: true,
            writesProvenance: true,
            recordsAnnotationInput: false
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ],
            annotationSidecarURL: sidecarURL
        )

        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: snapshot,
                format: .csv,
                to: outputURL
            )
        )
    }

    func testFailedOverwriteRestoresExistingOutputProvenanceAndProjection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let outputURL = root.appendingPathComponent("export.xlsx").standardizedFileURL
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let projectionURL = outputURL.appendingPathExtension("view-projection.json")
        let priorOutput = Data("prior-workbook".utf8)
        let priorProvenance = Data("prior-provenance".utf8)
        let priorProjection = Data("prior-projection".utf8)
        try priorOutput.write(to: outputURL)
        try priorProvenance.write(to: provenanceURL)
        try priorProjection.write(to: projectionURL)

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ]
        )

        let runner = StubGenotypeExportCLIRunner(
            writesOutput: true,
            writesProvenance: false
        )
        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: snapshot,
                format: .csv,
                to: outputURL
            )
        )

        XCTAssertEqual(try Data(contentsOf: outputURL), priorOutput)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
        XCTAssertEqual(try Data(contentsOf: projectionURL), priorProjection)
    }

    func testProjectionPadsRaggedRowsToColumnCount() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "test.lungfishgenotype")
        let outputURL = root.appendingPathComponent("export.csv")

        let runner = StubGenotypeExportCLIRunner(writesOutput: true, writesProvenance: true)
        // Three visible samples; only the first reports reads.
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "allele",
            filters: [:],
            sampleNames: ["S1", "S2", "S3"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "G1",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 10,
                    sampleReads: ["S1": 10],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ]
        )

        _ = try GenotypeViewportExportService(runner: runner).export(
            snapshot: snapshot,
            format: .csv,
            to: outputURL
        )

        XCTAssertEqual(try value(after: "--export-format", in: try XCTUnwrap(runner.invocations.first)), "csv")
        let projection = try XCTUnwrap(runner.capturedProjection)
        XCTAssertEqual(projection.sampleColumns.count, 3)
        for row in projection.rows {
            XCTAssertEqual(row.cells.count, 3, "every row must have one cell per visible sample")
            if let colors = row.cellColorsHex {
                XCTAssertEqual(colors.count, 3, "cell color array must match column count when present")
            }
        }
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeViewportExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(in root: URL, named name: String) throws -> URL {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))
        return bundleURL
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "GenotypeViewportExportTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }

    private func managedOpenpyxlPythonURL() -> URL? {
        if let configured = ProcessInfo.processInfo.environment[
            "LUNGFISH_TEST_PYTHON"
        ] {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"].flatMap { root in
            ["python3", "python"].map {
                home.appendingPathComponent(
                    "\(root)/conda/envs/openpyxl/bin/\($0)"
                )
            }
        }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runPython(
        _ python: URL,
        script: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeViewportExcelExportTests.Python",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    String(data: error, encoding: .utf8) ?? "Python failed"]
            )
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    private static let dumpScientificFilteredWorkbookScript = #"""
import json,sys
from openpyxl import load_workbook
wb=load_workbook(sys.argv[1], data_only=False)
receipt=json.load(open(sys.argv[1]+'.provenance.json'))
p=json.load(open(receipt['snapshot']['path']))
calls=wb['Haplotype Calls']
matrix=wb['Genotype Matrix - Filtered']
headers={c.value:c.column for c in calls[1]}
fields=['Sample','Locus','Effective H1','Effective H2','H1 status','H2 status','H1 source','H2 source','Pipeline H1','Pipeline H2']
evidence={r[0].value:r for r in matrix if r[0].value in {x['id'] for x in p['filteredMatrix']['rows']}}
assert len(evidence)==len(p['filteredMatrix']['rows'])
for r in p['filteredMatrix']['rows']: assert evidence[r['id']][2].value==r['displayName']
bands=[[r[3].value for r in wb[n] if r[2].value in ('H1','H2')] for n in ['Genotype Matrix - All','Genotype Matrix - Filtered']]
all_ids={r['id'] for r in p['allMatrix']['rows']}
out=dict(sheets=wb.sheetnames,call=[str(calls.cell(2,headers[f]).value or '') for f in fields],
 matrixRows=[[r['target']['genotype'],evidence[r['id']][1].value,r['target'].get('stableClusterID') or '',str(evidence[r['id']][3].value)] for r in p['filteredMatrix']['rows']],
 allRows=sum(r[0].value in all_ids for r in wb['Genotype Matrix - All']),bands=bands,
 metadata={str(r[0].value or ''):str(r[1].value or '') for r in wb['Export Metadata']},
 formulaCount=sum(c.data_type=='f' for s in wb for row in s for c in row))
print(json.dumps(out))
"""#
}

private extension Array where Element == String {
    func containsSubsequence(_ expected: [String]) -> Bool {
        guard !expected.isEmpty, expected.count <= count else { return false }
        return indices.contains { start in
            let end = index(start, offsetBy: expected.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[start..<end]) == expected
        }
    }
}

/// A recording-but-real runner: it captures the argv and the projection JSON
/// the service wrote, then (optionally) writes a real provenance sidecar so the
/// service's `verifyProvenance` succeeds. Mirrors `StubTwelveSExportCLIRunner`.
private final class StubGenotypeExportCLIRunner: GenotypeViewportExportRunning {
    private(set) var invocations: [[String]] = []
    private(set) var capturedProjection: GenotypeViewProjection?
    let writesOutput: Bool
    let writesProvenance: Bool
    let toolName: String
    let recordsAnnotationInput: Bool

    init(
        writesOutput: Bool,
        writesProvenance: Bool,
        toolName: String = "lungfish-cli",
        recordsAnnotationInput: Bool = false
    ) {
        self.writesOutput = writesOutput
        self.writesProvenance = writesProvenance
        self.toolName = toolName
        self.recordsAnnotationInput = recordsAnnotationInput
    }

    func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
        invocations.append(arguments)
        // Decode the projection the service handed us before it is cleaned up.
        if let projectionPath = try? value(after: "--view-projection", in: arguments) {
            let data = try Data(contentsOf: URL(fileURLWithPath: projectionPath))
            capturedProjection = try JSONDecoder().decode(GenotypeViewProjection.self, from: data)
        }
        let outputURL = URL(fileURLWithPath: try value(after: "--output", in: arguments))
        if writesOutput {
            try Data("genotype,reads\n".utf8).write(to: outputURL)
        }
        if writesProvenance {
            let argv = ["lungfish-cli"] + arguments
            var builder = try ProvenanceRunBuilder(
                workflowName: "lungfish genotype export",
                workflowVersion: "test",
                toolName: toolName,
                toolVersion: "test"
            )
            .argv(argv)
            .durableReplayArgv(argv)
            .reproducibleCommand(argv.joined(separator: " "))
            .output(outputURL, format: .unknown, role: .output)
            .runtime(ProvenanceRuntimeIdentity(user: "test"))
            if let projectionPath = try? value(after: "--view-projection", in: arguments) {
                builder = try builder.input(URL(fileURLWithPath: projectionPath), format: .json, role: .input)
            }
            if recordsAnnotationInput,
               let annotationsPath = try? value(after: "--annotations", in: arguments) {
                builder = try builder.input(URL(fileURLWithPath: annotationsPath), format: .json, role: .input)
            }
            let envelope = try builder.complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
            try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
            )
        }
        return LungfishCLIRunner.Output(stdout: "", stderr: "", status: 0)
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "StubGenotypeExportCLIRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }
}
