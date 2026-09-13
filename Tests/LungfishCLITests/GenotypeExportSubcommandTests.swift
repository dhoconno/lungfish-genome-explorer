import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class GenotypeExportSubcommandTests: XCTestCase {
    private static var managedPythonURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"]
            .map { root.appendingPathComponent("\($0)/conda/envs/openpyxl/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func testParsesReviewedXlsxScopeAndFilterOptions() throws {
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", "/tmp/input.lungfishgenotype",
            "--output", "/tmp/report.xlsx",
            "--lens", "allele",
            "--min-reads", "7",
            "--min-percent", "4.5",
            "--percent-basis", "sample-retained",
            "--filter", "reviewed",
            "--sample", "S2",
            "--view-projection", "/tmp/view.json",
            "--annotations", "/tmp/annotations.json",
            "--force",
        ])
        XCTAssertEqual(command.format, .xlsx)
        XCTAssertEqual(command.minReads, 7)
        XCTAssertEqual(command.minPercent, 4.5)
        XCTAssertEqual(command.percentBasis, .sampleRetained)
        XCTAssertEqual(command.samples, ["S2"])
        XCTAssertTrue(command.force)
    }

    func testRejectsInvalidInputsAndFilters() {
        XCTAssertThrowsError(
            try GenotypeExportSubcommand.parse([
                "--bundle", "", "--output", "/tmp/report.xlsx",
            ]).validate()
        )
        for arguments in [
            ["--min-reads", "-1"],
            ["--min-percent", "-0.1"],
            ["--min-percent", "100.1"],
        ] {
            XCTAssertThrowsError(
                try GenotypeExportSubcommand.parse(
                    ["--bundle", "/tmp/in", "--output", "/tmp/out.xlsx"]
                        + arguments
                ).validate()
            )
        }
    }

    func testProjectionRoundTripKeepsScientificNestedFields() throws {
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: [
                .init(
                    label: "short",
                    rawGenotype: "01_M1A_A1_063",
                    locus: "Mafa-A",
                    stableClusterID: "cluster-1",
                    cells: ["39"],
                    cellColorsHex: ["#123456"],
                    rowColorHex: "#ABCDEF",
                    rowStyle: .init(fillHex: "#ABCDEF", isBold: true),
                    cellStyles: [.init(textHex: "#FFFFFF", isItalic: true)],
                    matrixColumnValues: [
                        .init(key: "standard.genotype", text: "01_M1A_A1_063"),
                        .init(key: "standard.totalUniqueReads", integer: 39),
                    ]
                ),
            ],
            cellColorMode: "read-depth",
            genotypeLocusDisplayOrder: ["Mafa-A"],
            genotypeNumericPrefixOrder: true,
            diagnosticAllelesOnly: true,
            includeTotalReads: true,
            matrixColumns: [
                .init(key: "standard.genotype", title: "Genotype", kind: .genotype),
                .init(key: "standard.totalUniqueReads", title: "Total Reads", kind: .totalUniqueReads),
            ],
            haplotypeCalls: [
                .init(
                    sample: "S1", locus: "MHC-A", haplotype1: "M1A",
                    haplotype2: "M3A", haplotype1Status: "called",
                    haplotype2Status: "called", haplotype1Source: "pipeline",
                    haplotype2Source: "pipeline", baselineHaplotype1: "M1A",
                    baselineHaplotype2: "M3A", comment: "captured"
                ),
            ],
            sourceRevision: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: nil,
                definitionSetID: "mauritian-cynomolgus-macaques"
            ),
            filterContext: ["Search": "A1"],
            presentationColors: [
                .init(locus: "MHC-A", call: "M1A", fillHex: "#008000", fontHex: "#FFFFFF"),
            ]
        )

        let decoded = try JSONDecoder().decode(
            GenotypeViewProjection.self,
            from: JSONEncoder().encode(projection)
        )
        XCTAssertEqual(decoded.rows.first?.rawGenotype, "01_M1A_A1_063")
        XCTAssertEqual(decoded.rows.first?.stableClusterID, "cluster-1")
        XCTAssertEqual(decoded.rows.first?.cellStyles?.first??.textHex, "#FFFFFF")
        XCTAssertEqual(decoded.matrixColumns?.map(\.key), ["standard.genotype", "standard.totalUniqueReads"])
        XCTAssertEqual(decoded.rows.first?.matrixColumnValues?.last?.integer, 39)
        XCTAssertEqual(decoded.haplotypeCalls?.first?.baselineHaplotype2, "M3A")
        XCTAssertEqual(decoded.filterContext?["Search"], "A1")
        XCTAssertEqual(decoded.presentationColors?.first?.fillHex, "#008000")
    }

    func testCsvAndTsvExportsRemainOnTheNativeDelimitedPath() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)

        let csv = root.appendingPathComponent("matrix.csv")
        let csvColumns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "csv",
            "--output", csv.path,
            "--sample", "S1",
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("CSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(csvColumns, ["S1"])
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(csvText.hasPrefix("Sample,MHC-A H1,MHC-A H2\n"))
        XCTAssertTrue(csvText.contains("S1,M1A,M3A"))

        let projectionURL = root.appendingPathComponent("view.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1", "S2"],
                rows: [
                    .init(label: "Visible allele", locus: "Mafa-A", cells: ["39", "20"]),
                ]
            )
        ).write(to: projectionURL)
        let tsv = root.appendingPathComponent("view.tsv")
        let tsvColumns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "tsv",
            "--output", tsv.path,
            "--view-projection", projectionURL.path,
            "--sample", "S2",
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("TSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(tsvColumns, ["S2"])
        XCTAssertEqual(
            try String(contentsOf: tsv, encoding: .utf8),
            "Locus\tRow\tS2\nMafa-A\tVisible allele\t20\n"
        )
    }

    func testUnifiedXlsxUsesCapturedProjectionIdentityAnnotationsAndReceipt() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-unified-xlsx")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let loaded = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let call = try XCTUnwrap(loaded.calls.first)
        let lowCall = try XCTUnwrap(
            loaded.calls.first { $0.genotype == "02_M3A_A2_010" }
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: call.locusGroup,
            genotype: call.genotype,
            sample: "S1"
        )
        sidecar.matrixReviews = [
            .init(
                target: target, disposition: .falsePositive,
                author: "Reviewer", timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target, body: "captured note",
                author: "Reviewer", timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        try FileManager.default.removeItem(
            at: ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundle
            )
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundle
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [
                    .init(
                        label: "Concise A1",
                        rawGenotype: call.genotype,
                        locus: call.locusGroup,
                        cells: [String(call.passedUniqueReads)],
                        cellColorsHex: ["#123456"],
                        rowColorHex: "#ABCDEF"
                    ),
                    .init(
                        label: "Concise A2",
                        rawGenotype: lowCall.genotype,
                        locus: lowCall.locusGroup,
                        cells: [String(lowCall.passedUniqueReads)]
                    ),
                ],
                haplotypeLocusScope: [],
                filterContext: ["Search": "A1"]
            )
        ).write(to: projectionURL)
        let output = root.appendingPathComponent("report.xlsx")

        let columns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "xlsx",
            "--output", output.path,
            "--view-projection", projectionURL.path,
            "--min-reads", "31",
            "--sample", "S1",
        ]).runReturningResolvedColumns(managedPythonResolver: { python })

        XCTAssertEqual(columns, ["S1"])
        let receiptURL = output.appendingPathExtension("provenance.json")
        let receipt = try jsonObject(receiptURL)
        XCTAssertEqual(receipt["workflowName"] as? String, "lungfish genotype export")
        XCTAssertEqual((receipt["output"] as? [String: Any])?["path"] as? String, output.path)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        let snapshotDescriptor = try XCTUnwrap(receipt["snapshot"] as? [String: Any])
        let snapshotURL = URL(fileURLWithPath: try XCTUnwrap(snapshotDescriptor["path"] as? String))
        let snapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first)
        XCTAssertEqual(snapshot.filteredMatrix.rows.count, 1)
        XCTAssertTrue(snapshot.filteredMatrix.loci.isEmpty, "Explicit empty band scope survives CLI --sample projection")
        XCTAssertFalse(snapshot.allMatrix.loci.isEmpty)
        XCTAssertEqual(row.displayName, "Concise A1")
        XCTAssertEqual(row.target.genotype, call.genotype)
        XCTAssertEqual(row.cells.first?.review, "false-positive")
        XCTAssertEqual(row.cells.first?.comment, "captured note")
        XCTAssertEqual(row.cells.first?.fillHex?.uppercased(), "#123456")
        XCTAssertEqual(snapshot.allMatrix.samples.map(\.id), ["S1", "S2"])
        XCTAssertTrue(
            (receipt["inputs"] as? [[String: Any]] ?? []).contains {
                $0["path"] as? String == projectionURL.path
                    && ($0["sha256"] as? String)?.isEmpty == false
            }
        )

        let inspection = try await inspect(output, python: python, root: root)
        XCTAssertEqual(
            inspection["sheets"] as? [String],
            [
                "Haplotype Calls", "Genotype Matrix - All",
                "Genotype Matrix - Filtered", "Export Metadata",
            ]
        )
        XCTAssertEqual(inspection["filteredSamples"] as? [String], ["S1"])
        XCTAssertEqual(inspection["filteredLabel"] as? String, "Concise A1")
        XCTAssertEqual(inspection["filteredValue"] as? Int, call.passedUniqueReads)
        XCTAssertTrue((inspection["filteredComment"] as? String ?? "").contains("captured note"))
    }

    func testMalformedProjectionIsRejectedBeforeExistingReportIsReplaced() async throws {
        let root = try temporaryDirectory(prefix: "genotype-malformed-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let projection = root.appendingPathComponent("malformed.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [.init(label: "bad", cells: [])]
            )
        ).write(to: projection)
        let output = root.appendingPathComponent("existing.xlsx")
        let prior = Data("existing owner".utf8)
        try prior.write(to: output)

        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", output.path,
                "--view-projection", projection.path,
                "--force",
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("malformed projection must fail before runtime resolution")
                throw CocoaError(.fileNoSuchFile)
            })
            XCTFail("malformed projection was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("one value/style per sample")
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), prior)
    }

    func testExternalManifestSummaryIsCapturedExactlyAndMutationRejectsPublication() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-external-summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let internalSummary = bundle.appendingPathComponent("calls.csv")
        let externalSummary = root.appendingPathComponent("authoritative-summary.scientific-input")
        let originalBytes = try Data(contentsOf: internalSummary)
        try originalBytes.write(to: externalSummary)
        try pointManifestLongSummary(in: bundle, at: externalSummary)

        let output = root.appendingPathComponent("external.xlsx")
        _ = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
        ]).runReturningResolvedColumns(managedPythonResolver: { python })

        let receipt = try jsonObject(output.appendingPathExtension("provenance.json"))
        let witness = try XCTUnwrap(
            (receipt["inputs"] as? [[String: Any]])?.first {
                $0["path"] as? String == externalSummary.path
            }
        )
        XCTAssertEqual(witness["sizeBytes"] as? Int, originalBytes.count)
        XCTAssertEqual(
            witness["sha256"] as? String,
            try ProvenanceFileHasher.sha256(of: externalSummary)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(
                    fileURLWithPath: try XCTUnwrap(witness["capturedPath"] as? String)
                )
            ),
            originalBytes
        )

        let forced = root.appendingPathComponent("forced-existing.xlsx")
        let forcedReceipt = forced.appendingPathExtension("provenance.json")
        let priorOutput = Data("existing output owner".utf8)
        let priorReceipt = Data("existing receipt owner".utf8)
        try priorOutput.write(to: forced)
        try priorReceipt.write(to: forcedReceipt)
        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", forced.path,
                "--force",
            ]).runReturningResolvedColumns(managedPythonResolver: {
                try Data("mutated after scientific capture".utf8).write(
                    to: externalSummary,
                    options: .atomic
                )
                return python
            })
            XCTFail("mutated external scientific input was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("scientific input changed"),
                String(describing: error)
            )
        }
        XCTAssertEqual(try Data(contentsOf: forced), priorOutput)
        XCTAssertEqual(try Data(contentsOf: forcedReceipt), priorReceipt)
    }

    func testCustomDefinitionMutationAfterCaptureRejectsForcedPublication() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-definition-mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analysisRoot = project.appendingPathComponent("Analyses/Run", isDirectory: true)
        try FileManager.default.createDirectory(at: analysisRoot, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: analysisRoot)
        let store = HaplotypeDefinitionStore(projectRoot: project)
        try store.ensureFolderExists()
        let definitionURL = try XCTUnwrap(store.definitionURL(for: "mauritian-cynomolgus-macaques"))
        let definitionA = GenotypeHaplotypeDefinitionSet(
            id: "mauritian-cynomolgus-macaques",
            assayID: "MHC-exon2-miSeq",
            displayName: "Captured definition A",
            speciesName: "Fixture",
            speciesCode: "Fixture",
            prefix: "Mafa",
            locusDefinitions: []
        )
        let definitionB = GenotypeHaplotypeDefinitionSet(
            id: definitionA.id,
            assayID: definitionA.assayID,
            displayName: "Replacement definition B",
            speciesName: definitionA.speciesName,
            speciesCode: definitionA.speciesCode,
            prefix: definitionA.prefix,
            locusDefinitions: []
        )
        try JSONEncoder().encode(definitionA).write(to: definitionURL, options: .atomic)
        let output = root.appendingPathComponent("existing.xlsx")
        let receipt = output.appendingPathExtension("provenance.json")
        let priorOutput = Data("existing output owner".utf8)
        let priorReceipt = Data("existing receipt owner".utf8)
        try priorOutput.write(to: output)
        try priorReceipt.write(to: receipt)

        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", output.path,
                "--force",
            ]).runReturningResolvedColumns(
                afterExcelAuthorityCapture: {
                    try JSONEncoder().encode(definitionB).write(
                        to: definitionURL,
                        options: .atomic
                    )
                },
                managedPythonResolver: { python }
            )
            XCTFail("definition mutation after capture was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("definition")
                    && String(describing: error).contains("changed"),
                String(describing: error)
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), priorOutput)
        XCTAssertEqual(try Data(contentsOf: receipt), priorReceipt)
    }

    func testManifestDiscoveryAndLoadedResultRemainBoundToCapturedBytes() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-manifest-generation")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let replacementSummary = root.appendingPathComponent("generation-b.evidence")
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,99_generation_B,91,91,100,91,91.0,1000,91,9.1
        """.write(to: replacementSummary, atomically: true, encoding: .utf8)
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: bundle)
        var generationB = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        generationB["longSummaryCSVPath"] = replacementSummary.path
        let generationBData = try JSONSerialization.data(
            withJSONObject: generationB,
            options: [.prettyPrinted, .sortedKeys]
        )
        let output = root.appendingPathComponent("existing.xlsx")
        let receipt = output.appendingPathExtension("provenance.json")
        let priorOutput = Data("existing output owner".utf8)
        let priorReceipt = Data("existing receipt owner".utf8)
        try priorOutput.write(to: output)
        try priorReceipt.write(to: receipt)

        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", output.path,
                "--force",
            ]).runReturningResolvedColumns(
                afterExcelManifestDecode: {
                    try generationBData.write(to: manifestURL, options: .atomic)
                },
                managedPythonResolver: {
                    XCTFail("manifest generation mismatch must fail before rendering")
                    return python
                }
            )
            XCTFail("result loaded from manifest B after discovery from A")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("manifest")
                    || String(describing: error).contains("scientific input changed"),
                String(describing: error)
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), priorOutput)
        XCTAssertEqual(try Data(contentsOf: receipt), priorReceipt)
    }

    func testExternalReferenceOrderManifestIsWitnessedAndMutationRejectsPublication() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-reference-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let reference = root.appendingPathComponent(
            "ordering.lungfishmhcref",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        let orderA = MHCAmpliconReferenceBundleManifest(
            name: "Ordering A",
            referenceFastaPath: "reference.fasta",
            referenceBundlePath: nil,
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: .init(referenceCount: 0, haplotypeDefinitionCount: 0),
            genotypeLocusDisplayOrder: ["MHC-B", "MHC-A"],
            createdAt: "2026-09-12T00:00:00Z"
        )
        let orderB = MHCAmpliconReferenceBundleManifest(
            name: "Ordering B",
            referenceFastaPath: "reference.fasta",
            referenceBundlePath: nil,
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: .init(referenceCount: 0, haplotypeDefinitionCount: 0),
            genotypeLocusDisplayOrder: ["MHC-A", "MHC-B"],
            createdAt: "2026-09-12T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(orderA, to: reference)
        try JSONSerialization.data(
            withJSONObject: [
                "argv": [
                    "lungfish-cli", "fastq", "genotype-cohort",
                    "--reference", reference.path,
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: bundle.appendingPathComponent("provenance.json"), options: .atomic)

        let output = root.appendingPathComponent("reference-order.xlsx")
        _ = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--output", output.path,
        ]).runReturningResolvedColumns(managedPythonResolver: { python })

        let referenceManifestURL = MHCAmpliconReferenceBundle.manifestURL(in: reference)
        let originalBytes = try Data(contentsOf: referenceManifestURL)
        let receiptObject = try jsonObject(output.appendingPathExtension("provenance.json"))
        let witness = try XCTUnwrap(
            (receiptObject["inputs"] as? [[String: Any]])?.first {
                $0["path"] as? String == referenceManifestURL.path
            }
        )
        XCTAssertEqual(witness["sizeBytes"] as? Int, originalBytes.count)
        XCTAssertEqual(
            witness["sha256"] as? String,
            try ProvenanceFileHasher.sha256(of: referenceManifestURL)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(
                    fileURLWithPath: try XCTUnwrap(witness["capturedPath"] as? String)
                )
            ),
            originalBytes
        )

        let forced = root.appendingPathComponent("forced-existing.xlsx")
        let forcedReceipt = forced.appendingPathExtension("provenance.json")
        let priorOutput = Data("existing output owner".utf8)
        let priorReceipt = Data("existing receipt owner".utf8)
        try priorOutput.write(to: forced)
        try priorReceipt.write(to: forcedReceipt)
        try originalBytes.write(to: referenceManifestURL, options: .atomic)
        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", forced.path,
                "--force",
            ]).runReturningResolvedColumns(
                afterExcelAuthorityCapture: {
                    try MHCAmpliconReferenceBundle.writeManifest(orderB, to: reference)
                },
                managedPythonResolver: { python }
            )
            XCTFail("mutated reference-order authority was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("scientific input changed"),
                String(describing: error)
            )
        }
        XCTAssertEqual(try Data(contentsOf: forced), priorOutput)
        XCTAssertEqual(try Data(contentsOf: forcedReceipt), priorReceipt)
    }

    // These delimiter-path tests preserve the publication transaction's
    // compare-and-swap and rollback guarantees independently of XLSX. They
    // intentionally never resolve or invoke the spreadsheet renderer.
    func testDelimitedExportRestoresPriorOutputWhenProvenancePublicationFails() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-provenance-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("existing.csv")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let rootProvenance = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let priorOutput = Data("prior delimited output".utf8)
        let priorSidecar = Data("prior output provenance".utf8)
        let priorRoot = Data("prior root provenance".utf8)
        try priorOutput.write(to: output)
        try priorSidecar.write(to: sidecar)
        try priorRoot.write(to: rootProvenance)

        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "csv", force: true)
                .runReturningResolvedColumns(beforeProvenancePublication: {
                    throw NSError(domain: "GenotypeExportSubcommandTests", code: 91,
                        userInfo: [NSLocalizedDescriptionKey: "Injected provenance publication failure"])
                })
            XCTFail("expected injected provenance failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provenance publication failure"))
        }
        XCTAssertEqual(try Data(contentsOf: output), priorOutput)
        XCTAssertEqual(try Data(contentsOf: sidecar), priorSidecar)
        XCTAssertEqual(try Data(contentsOf: rootProvenance), priorRoot)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("export-staging") })
    }

    func testDelimitedRollbackPreservesNoncooperatingWriterChanges() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-cas-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("shared.tsv")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let rootProvenance = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenanceDirectory = root.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
        let generation = provenanceDirectory.appendingPathComponent("bundle-provenance.json")
        try FileManager.default.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)
        try Data("prior delimited output".utf8).write(to: output)
        try Data("prior output provenance".utf8).write(to: sidecar)
        try Data("prior root provenance".utf8).write(to: rootProvenance)
        try Data("prior provenance generation".utf8).write(to: generation)
        let priorGenerationInode = try inode(of: generation)
        let externalOutput = Data("noncooperating delimited output".utf8)
        let externalRoot = Data("noncooperating root provenance".utf8)
        let externalGeneration = Data("noncooperating provenance generation".utf8)
        var writerFired = false
        var externalRootInode: UInt64?
        var failureDescription = ""

        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "tsv", force: true)
                .runReturningResolvedColumns(
                    beforeProvenanceArtifactObservation: { mutation in
                        guard mutation.kind == .provenanceDocumentWritten,
                              mutation.url.standardizedFileURL == rootProvenance.standardizedFileURL,
                              !writerFired else { return }
                        writerFired = true
                        try externalOutput.write(to: output, options: .atomic)
                        try self.overwriteInPlace(rootProvenance, with: externalRoot)
                        externalRootInode = try self.inode(of: rootProvenance)
                        try self.overwriteInPlace(generation, with: externalGeneration)
                    },
                    afterProvenanceArtifactPublication: { mutation in
                        guard mutation.kind == .provenanceDocumentWritten,
                              mutation.url.standardizedFileURL == sidecar.standardizedFileURL else { return }
                        throw NSError(domain: "GenotypeExportSubcommandTests", code: 96,
                            userInfo: [NSLocalizedDescriptionKey: "Injected failure after later provenance mutation"])
                    })
            XCTFail("expected injected publication failure")
        } catch {
            failureDescription = String(describing: error)
            XCTAssertTrue(failureDescription.contains("Injected failure after later provenance mutation"))
            XCTAssertTrue(failureDescription.contains(output.path))
        }
        XCTAssertTrue(writerFired)
        XCTAssertEqual(try Data(contentsOf: output), externalOutput)
        XCTAssertEqual(try Data(contentsOf: rootProvenance), externalRoot)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("prior output provenance".utf8))
        XCTAssertEqual(try Data(contentsOf: generation), externalGeneration)
        XCTAssertEqual(try inode(of: rootProvenance), externalRootInode)
        XCTAssertEqual(try inode(of: generation), priorGenerationInode)
        let quarantines = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".shared.tsv.provenance-forward-") }
        XCTAssertEqual(quarantines.count, 1)
        let quarantine = try XCTUnwrap(quarantines.first)
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("prior delimited output".utf8))
        XCTAssertTrue(failureDescription.contains(quarantine.lastPathComponent))
    }

    func testDelimitedRollbackSnapshotRejectsChangeBetweenBackupAndBoundWitness() throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-snapshot-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("shared.csv")
        let external = Data("external generation".utf8)
        try Data("original generation".utf8).write(to: output)
        XCTAssertThrowsError(try ProvenancePublicationSnapshot(urls: [output], afterBackupCopy: { copied in
            XCTAssertEqual(copied.standardizedFileURL, output.standardizedFileURL)
            try external.write(to: output, options: .atomic)
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed while its rollback snapshot"))
        }
        XCTAssertEqual(try Data(contentsOf: output), external)
    }

    func testForcedDelimitedExportDoesNotDeleteReplacementArrivingBeforeClaim() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-forward-claim")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("shared.tsv")
        let external = Data("external generation".utf8)
        try Data("prior generation".utf8).write(to: output)
        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "tsv", force: true)
                .runReturningResolvedColumns(beforeOutputReplacementClaim: {
                    try external.write(to: output, options: .atomic)
                })
            XCTFail("expected generation conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(output.path))
        }
        XCTAssertEqual(try Data(contentsOf: output), external)
    }

    func testDelimitedRollbackRestoresAfterEachPublishedProvenanceArtifact() async throws {
        enum FailureTarget: String, CaseIterable { case root, bundleRollup, focusedBundleSidecar, outputSidecar }
        for target in FailureTarget.allCases {
            let root = try temporaryDirectory(prefix: "genotype-delimited-artifact-rollback-\(target.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = try makeBundle(in: root)
            let publicationRoot = root.appendingPathComponent("publication.lungfishresults", isDirectory: true)
            try FileManager.default.createDirectory(at: publicationRoot, withIntermediateDirectories: true)
            let output = publicationRoot.appendingPathComponent("existing.csv")
            let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
            let rootProvenance = publicationRoot.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            let provenanceDirectory = publicationRoot.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            let rollup = provenanceDirectory.appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
            let focused = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(for: output, inBundle: publicationRoot))
            let failureURL: URL
            switch target { case .root: failureURL = rootProvenance; case .bundleRollup: failureURL = rollup; case .focusedBundleSidecar: failureURL = focused; case .outputSidecar: failureURL = sidecar }
            let priorOutput = Data("prior delimited output".utf8)
            let priorSidecar = Data("prior output provenance".utf8)
            let priorRoot = Data("prior root provenance".utf8)
            try priorOutput.write(to: output); try priorSidecar.write(to: sidecar); try priorRoot.write(to: rootProvenance)
            do {
                _ = try await delimitedCommand(bundle: bundle, output: output, format: "csv", force: true)
                    .runReturningResolvedColumns(afterProvenanceArtifactPublication: { mutation in
                        guard mutation.kind == .provenanceDocumentWritten,
                              mutation.url.standardizedFileURL == failureURL.standardizedFileURL else { return }
                        throw NSError(domain: "GenotypeExportSubcommandTests", code: 97,
                            userInfo: [NSLocalizedDescriptionKey: "Injected failure after \(target.rawValue) provenance mutation"])
                    })
                XCTFail("expected provenance artifact failure")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Injected failure after \(target.rawValue) provenance mutation"))
            }
            XCTAssertEqual(try Data(contentsOf: output), priorOutput)
            XCTAssertEqual(try Data(contentsOf: sidecar), priorSidecar)
            XCTAssertEqual(try Data(contentsOf: rootProvenance), priorRoot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: provenanceDirectory.path))
        }
    }

    func testDelimitedRollbackRestoresRemovedStaleSigningArtifacts() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-signing-removal")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("existing.tsv")
        let rootProvenance = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let signature = ProvenanceSigningConfiguration.signatureURL(for: rootProvenance)
        let publicKey = ProvenanceSigningConfiguration.publicKeyURL(for: rootProvenance)
        let priorOutput = Data("prior delimited output".utf8), priorRoot = Data("prior root provenance".utf8)
        let priorSignature = Data("prior signature".utf8), priorPublicKey = Data("prior public key".utf8)
        try priorOutput.write(to: output); try priorRoot.write(to: rootProvenance)
        try priorSignature.write(to: signature); try priorPublicKey.write(to: publicKey)
        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "tsv", force: true)
                .runReturningResolvedColumns(afterProvenanceArtifactPublication: { mutation in
                    guard mutation.kind == .artifactRemoved, mutation.affectedURLs.contains(signature) else { return }
                    throw NSError(domain: "GenotypeExportSubcommandTests", code: 101,
                        userInfo: [NSLocalizedDescriptionKey: "Injected failure after signing artifact removal"])
                })
            XCTFail("expected signing artifact removal failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected failure after signing artifact removal"))
        }
        XCTAssertEqual(try Data(contentsOf: output), priorOutput)
        XCTAssertEqual(try Data(contentsOf: rootProvenance), priorRoot)
        XCTAssertEqual(try Data(contentsOf: signature), priorSignature)
        XCTAssertEqual(try Data(contentsOf: publicKey), priorPublicKey)
    }

    func testDelimitedRollbackDoesNotDeleteWriterArrivingAfterAtomicDetachment() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-detach-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("shared.csv")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let rootProvenance = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let priorSidecar = Data("prior sidecar".utf8), priorRoot = Data("prior root".utf8)
        let late = Data("late external delimited output".utf8)
        try Data("prior delimited output".utf8).write(to: output); try priorSidecar.write(to: sidecar); try priorRoot.write(to: rootProvenance)
        var writerFired = false
        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "csv", force: true)
                .runReturningResolvedColumns(
                    beforeProvenancePublication: {
                        throw NSError(domain: "GenotypeExportSubcommandTests", code: 100,
                            userInfo: [NSLocalizedDescriptionKey: "Injected pre-provenance failure"])
                    },
                    afterRollbackArtifactDetached: { detached in
                        guard detached.standardizedFileURL == output.standardizedFileURL, !writerFired else { return }
                        writerFired = true
                        try late.write(to: output, options: .atomic)
                    })
            XCTFail("expected injected pre-provenance failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected pre-provenance failure"))
        }
        XCTAssertTrue(writerFired)
        XCTAssertEqual(try Data(contentsOf: output), late)
        XCTAssertEqual(try Data(contentsOf: sidecar), priorSidecar)
        XCTAssertEqual(try Data(contentsOf: rootProvenance), priorRoot)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.contains(".provenance-rollback-") || $0.contains(".provenance-restore-")
        })
    }

    func testDelimitedExportWithoutForcePreservesOutputCreatedDuringRendering() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-late-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let output = root.appendingPathComponent("late.tsv")
        let late = Data("created by another actor".utf8)
        do {
            _ = try await delimitedCommand(bundle: bundle, output: output, format: "tsv", force: false)
                .runReturningResolvedColumns(beforeOutputPublication: {
                    try late.write(to: output, options: .atomic)
                })
            XCTFail("expected exclusive publication to reject late output")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Output file already exists"), "unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: output), late)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("lungfish-provenance.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("export-staging") })
    }

    func testConcurrentDelimitedExportsSerializeSharedRootProvenanceRollback() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited-concurrent-provenance")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let outputA = root.appendingPathComponent("export-a.csv")
        let outputB = root.appendingPathComponent("export-b.tsv")
        let rootProvenance = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let commandA = try delimitedCommand(bundle: bundle, output: outputA, format: "csv", force: false)
        let commandB = try delimitedCommand(bundle: bundle, output: outputB, format: "tsv", force: false)
        let aReached = DispatchSemaphore(value: 0), releaseA = DispatchSemaphore(value: 0)
        let bReady = DispatchSemaphore(value: 0), allowB = DispatchSemaphore(value: 0)
        let bReached = DispatchSemaphore(value: 0), releaseB = DispatchSemaphore(value: 0)
        defer { releaseA.signal(); allowB.signal(); releaseB.signal() }
        let taskA = Task.detached {
            try await commandA.runReturningResolvedColumns(beforeProvenancePublication: {
                aReached.signal()
                guard releaseA.wait(timeout: .now() + 10) == .success else {
                    throw NSError(domain: "GenotypeExportSubcommandTests", code: 92,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out releasing export A"])
                }
            })
        }
        XCTAssertEqual(aReached.wait(timeout: .now() + 10), .success)
        let taskB = Task.detached {
            try await commandB.runReturningResolvedColumns(
                beforeOutputPublication: {
                    bReady.signal()
                    guard allowB.wait(timeout: .now() + 10) == .success else {
                        throw NSError(domain: "GenotypeExportSubcommandTests", code: 93,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out starting export B publication"])
                    }
                },
                beforeProvenancePublication: {
                    bReached.signal()
                    guard releaseB.wait(timeout: .now() + 10) == .success else {
                        throw NSError(domain: "GenotypeExportSubcommandTests", code: 94,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out releasing export B"])
                    }
                    throw NSError(domain: "GenotypeExportSubcommandTests", code: 95,
                        userInfo: [NSLocalizedDescriptionKey: "Injected concurrent provenance failure"])
                })
        }
        XCTAssertEqual(bReady.wait(timeout: .now() + 10), .success)
        allowB.signal()
        XCTAssertEqual(bReached.wait(timeout: .now() + 0.25), .timedOut)
        releaseA.signal(); _ = try await taskA.value
        XCTAssertEqual(bReached.wait(timeout: .now() + 10), .success)
        let provenanceAfterA = try Data(contentsOf: rootProvenance)
        let sidecarA = outputA.appendingPathExtension("lungfish-provenance.json")
        let sidecarAfterA = try Data(contentsOf: sidecarA)
        releaseB.signal()
        do { _ = try await taskB.value; XCTFail("expected injected export B provenance failure") }
        catch { XCTAssertTrue(String(describing: error).contains("Injected concurrent provenance failure")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputB.path))
        XCTAssertEqual(try Data(contentsOf: rootProvenance), provenanceAfterA)
        XCTAssertEqual(try Data(contentsOf: sidecarA), sidecarAfterA)
    }

    private func delimitedCommand(bundle: URL, output: URL, format: String, force: Bool) throws -> GenotypeExportSubcommand {
        var arguments = ["--bundle", bundle.path, "--export-format", format, "--output", output.path]
        if force { arguments.append("--force") }
        return try GenotypeExportSubcommand.parse(arguments)
    }

    private func overwriteInPlace(_ url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func inode(of url: URL) throws -> UInt64 {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(information.st_ino)
    }

    private func makeBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let workbook = bundle.appendingPathComponent("source.xlsx")
        let calls = bundle.appendingPathComponent("calls.csv")
        let samples = bundle.appendingPathComponent("samples.csv")
        let stats = bundle.appendingPathComponent("stats.json")
        let provenance = bundle.appendingPathComponent("provenance.json")
        let analysisURL = bundle.appendingPathComponent("haplotypes.json")
        try Data("not a workbook and never an XLSX input".utf8).write(to: workbook)
        try Data("{}".utf8).write(to: provenance)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,01_M1A_A1_063,42,39,100,69,69.0,1000,89,8.9
        S1,02_M3A_A2_010,30,30,100,69,69.0,1000,89,8.9
        S2,01_M1A_A1_063,22,20,80,20,25.0,1000,89,8.9
        """.write(to: calls, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,72,69,100,69.0,1000,8.9
        S2,22,20,80,25.0,1000,8.9
        """.write(to: samples, atomically: true, encoding: .utf8)
        try Data(#"{"totalInputReads":1000,"totalAlignments":94,"passedAlignments":94,"retainedUniqueReads":89,"retainedUniquePercentOfTotalReads":8.9,"assignedUniqueRetainedReads":89,"unassignedUniqueRetainedReads":0}"#.utf8).write(to: stats)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Fixture",
            speciesName: "Fixture",
            generatedAt: "2026-09-12T00:00:00Z",
            samples: [
                .init(sample: "S1", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "M3A", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 2,
                        observedGenotypes: ["01_M1A_A1_063", "02_M3A_A2_010"]
                    ),
                ]),
                .init(sample: "S2", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "-", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 1,
                        observedGenotypes: ["01_M1A_A1_063"]
                    ),
                ]),
            ]
        )
        try JSONEncoder().encode(analysis).write(to: analysisURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbook.lastPathComponent,
            longSummaryCSVPath: calls.lastPathComponent,
            sampleSummaryCSVPath: samples.lastPathComponent,
            statsJSONPath: stats.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            haplotypeAnalysisPath: analysisURL.lastPathComponent,
            haplotypeDefinitionSetID: analysis.definitionSetID,
            createdAt: "2026-09-12T00:00:00Z"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-09-12T00:00:00Z"),
            forBundleAt: bundle
        )
        return bundle
    }

    private func pointManifestLongSummary(in bundle: URL, at url: URL) throws {
        let manifestURL = ONTGenotypeResultBundle.manifestURL(in: bundle)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        object["longSummaryCSVPath"] = url.standardizedFileURL.path
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL, options: .atomic)
    }

    private func inspect(
        _ workbook: URL,
        python: URL,
        root: URL
    ) async throws -> [String: Any] {
        let script = root.appendingPathComponent("inspect-\(UUID().uuidString).py")
        try Data(#"""
import json, sys
from openpyxl import load_workbook
w = load_workbook(sys.argv[1], data_only=False)
s = w['Genotype Matrix - Filtered']
header = next(r for r in range(1, s.max_row + 1) if s.cell(r, 3).value == 'Allele')
row = header + 1
print(json.dumps({
  'sheets': w.sheetnames,
  'filteredSamples': [s.cell(header, c).value for c in range(4, s.max_column + 1)],
  'filteredLabel': s.cell(row, 3).value,
  'filteredValue': s.cell(row, 4).value,
  'filteredComment': s.cell(row, 4).comment.text if s.cell(row, 4).comment else '',
}))
"""#.utf8).write(to: script)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, workbook.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: stdout.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
