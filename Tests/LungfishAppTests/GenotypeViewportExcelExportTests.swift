import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

final class GenotypeViewportExcelExportTests: XCTestCase {
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
            format: .excel,
            to: outputURL
        )

        XCTAssertEqual(result.outputURL, outputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        XCTAssertEqual(runner.invocations.count, 1)
        let arguments = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(arguments.prefix(2), ["genotype", "export"])
        XCTAssertEqual(try value(after: "--bundle", in: arguments), sourceBundle.path)
        XCTAssertEqual(try value(after: "--export-format", in: arguments), "xlsx")
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

        // The temp projection JSON the service wrote is cleaned up.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectionPath))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.workflowName, "lungfish genotype export")
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
                format: .excel,
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
                format: .excel,
                to: outputURL
            )
        )
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

    /// End-to-end: the GUI builds a projection from a snapshot, writes it to
    /// JSON, and the real CLI workbook writer (the same one `genotype export
    /// --view-projection` uses) reproduces the visible columns and an applied
    /// cell color. This guards the GUI→CLI projection contract without the
    /// flakiness of spawning the CLI process / needing a bundle fixture.
    func testProjectionRoundTripsThroughCLIWorkbookWriter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeBundle(in: root, named: "barcode05-mhc.lungfishgenotype")
        let outputURL = root.appendingPathComponent("barcode05-mhc-view.xlsx")

        let runner = StubGenotypeExportCLIRunner(writesOutput: true, writesProvenance: true)
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "barcode05-mhc",
            lens: "summary.matrix",
            filters: [:],
            sampleNames: ["AnimalA", "AnimalB"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [
                        "AnimalA": GenotypeResultHighlightStyle(
                            fillColor: AnnotationColor(red: 0.6, green: 0.8, blue: 1.0)
                        )
                    ]
                )
            ]
        )

        _ = try GenotypeViewportExportService(runner: runner).export(
            snapshot: snapshot,
            format: .excel,
            to: outputURL
        )

        // Feed the exact projection the GUI handed the CLI to the real writer.
        let projection = try XCTUnwrap(runner.capturedProjection)
        let writer = GenotypeXlsxWorkbookWriter()
        let workbookURL = root.appendingPathComponent("roundtrip.xlsx")
        try writer.writeViewProjection(projection, to: workbookURL)

        XCTAssertEqual(
            GenotypeXlsxWorkbookWriter.resolvedSampleColumns(for: projection),
            ["AnimalA", "AnimalB"]
        )
        // Visible columns survive into the rendered workbook.
        let delimited = GenotypeXlsxWorkbookWriter.renderDelimited(projection, separator: ",")
        XCTAssertTrue(delimited.contains("AnimalA"))
        XCTAssertTrue(delimited.contains("AnimalB"))
        XCTAssertTrue(delimited.contains("01_M1_A_01"))
        // At least one viewport color is applied (AARRGGBB: #99CCFF -> FF99CCFF).
        let styleXML = try unzipEntry("xl/styles.xml", from: workbookURL)
        XCTAssertTrue(
            styleXML.contains("FF99CCFF"),
            "expected the analyst's cell color to be reproduced in the workbook"
        )
    }

    // MARK: - Helpers

    private func unzipEntry(_ entry: String, from archiveURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archiveURL.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

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

    init(writesOutput: Bool, writesProvenance: Bool, toolName: String = "lungfish-cli") {
        self.writesOutput = writesOutput
        self.writesProvenance = writesProvenance
        self.toolName = toolName
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
            let envelope = try ProvenanceRunBuilder(
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
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
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
