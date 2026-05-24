import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishWorkflow

final class GenotypeViewportExcelExportTests: XCTestCase {
    func testExcelExportWritesWorkbookAndProvenancePackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeViewportExcelExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "barcode05-mhc",
            lens: "analyst",
            filters: ["locus": "MHC-A", "minimumSupportPercent": "1.0"],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(
                        fillColor: AnnotationColor(red: 0.2, green: 0.4, blue: 0.8),
                        borderColor: AnnotationColor(red: 0.9, green: 0.2, blue: 0.1)
                    ),
                    cellStyles: ["AnimalA": GenotypeResultHighlightStyle(fillColor: AnnotationColor(red: 0.6, green: 0.8, blue: 1.0))]
                )
            ]
        )

        let exportURL = root.appendingPathComponent("barcode05-mhc-review.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.workbookURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
        let worksheetXML = try unzipEntry("xl/worksheets/sheet1.xml", from: result.workbookURL)
        XCTAssertTrue(worksheetXML.contains("01_M1_A_01"))
        XCTAssertTrue(worksheetXML.contains("AnimalA"))
        let styleXML = try unzipEntry("xl/styles.xml", from: result.workbookURL)
        XCTAssertTrue(styleXML.contains("FF3366CC"))
        XCTAssertTrue(styleXML.contains("FFE6331A"))
        let provenance = try String(contentsOf: result.provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("Genotype viewport Excel export"))
        XCTAssertTrue(provenance.contains(result.workbookURL.lastPathComponent))
        XCTAssertFalse(provenance.contains(".xlsx-build"))
    }

    func testExcelExportIncludesOverridesAndAuditSheetsWhenSidecarProvided() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExcelExportSidecarTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "analyst",
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
            sidecar: GenotypeAnnotationSidecarSnapshot(
                overrides: [
                    GenotypeAnnotationOverrideEntry(
                        sample: "AnimalA", locus: "MHC-A", slot: "h2",
                        originalCall: "M2A", overrideCall: "A1_063",
                        reasonTag: "contamination",
                        rationale: "Adjacent contamination from H22C115",
                        author: "dho", timestamp: "2026-05-22T16:02:11Z"
                    )
                ],
                auditEntries: [
                    GenotypeAnnotationAuditEntry(
                        action: "override", sample: "AnimalA", locus: "MHC-A", slot: "h2",
                        before: "M2A", after: "A1_063",
                        author: "dho", timestamp: "2026-05-22T16:02:11Z"
                    )
                ]
            )
        )

        let exportURL = root.appendingPathComponent("export.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        let overridesXML = try unzipEntry("xl/worksheets/sheet3.xml", from: result.workbookURL)
        XCTAssertTrue(overridesXML.contains("A1_063"))
        XCTAssertTrue(overridesXML.contains("contamination"))
        let auditXML = try unzipEntry("xl/worksheets/sheet4.xml", from: result.workbookURL)
        XCTAssertTrue(auditXML.contains("override"))
        XCTAssertTrue(auditXML.contains("dho"))
        let workbookXML = try unzipEntry("xl/workbook.xml", from: result.workbookURL)
        XCTAssertTrue(workbookXML.contains("Overrides"))
        XCTAssertTrue(workbookXML.contains("Audit Log"))
    }

    func testExcelExportProvenanceIncludesAnnotationSidecarWhenExportingOverrideSheets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExcelExportProvenanceSidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))
        let annotationURL = sourceBundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try Data("{\"version\":1,\"generatedAt\":\"2026-05-23T00:00:00Z\"}".utf8).write(to: annotationURL)

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "analyst",
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
            sidecar: GenotypeAnnotationSidecarSnapshot(
                overrides: [
                    GenotypeAnnotationOverrideEntry(
                        sample: "AnimalA", locus: "MHC-A", slot: "h2",
                        originalCall: "M2A", overrideCall: "M1A",
                        reasonTag: "misCall", rationale: "manual review",
                        author: "dho", timestamp: "2026-05-23T00:00:00Z"
                    )
                ],
                auditEntries: [
                    GenotypeAnnotationAuditEntry(
                        action: "override", sample: "AnimalA", locus: "MHC-A", slot: "h2",
                        before: "M2A", after: "M1A",
                        author: "dho", timestamp: "2026-05-23T00:00:00Z"
                    )
                ]
            )
        )

        let exportURL = root.appendingPathComponent("export.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertTrue(envelope.files.contains { file in
            file.path == annotationURL.path && file.role == .input && file.checksumSHA256 != nil
        })
    }

    func testExcelExportProvenanceIncludesCustomHaplotypeDefinitionInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExcelExportDefinitionInput-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))
        let definitionURL = root.appendingPathComponent("custom.lungfishhaplotypedef.json")
        try Data("{\"id\":\"custom.definition\"}".utf8).write(to: definitionURL)

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix.haplotypeDefinitions",
            filters: ["activeHaplotypeDefinitionSetID": "custom.definition"],
            sampleNames: ["12_M9_B_001_01"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "NewB",
                    locus: "AnimalA MHC-B",
                    sampleCount: 1,
                    totalUniqueReads: 150,
                    sampleReads: ["12_M9_B_001_01": 150],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ],
            provenanceInputURLs: [definitionURL]
        )

        let exportURL = root.appendingPathComponent("export.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let hasDefinitionInput = envelope.files.contains { file in
            file.path == definitionURL.path && file.role == .input && file.checksumSHA256 != nil
        }
        XCTAssertTrue(hasDefinitionInput)
        let activeDefinition = envelope.options.resolvedDefaults["activeHaplotypeDefinitionSetID"]
        XCTAssertEqual(
            activeDefinition,
            ParameterValue.string("custom.definition")
        )
    }

    func testExcelExportProvenanceRecordsVisibleSamplesAndFilterContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExcelExportFilterContext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "test",
            lens: "summary.matrix",
            filters: [
                "activeSmartCohortName": "Filter: MHC-B",
                "activeSmartCohortPredicate": "textContains(MHC-B)",
                "quickFilter": "MHC-B",
            ],
            sampleNames: ["DW472", "DW474"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "12_M3_B_075_01",
                    locus: "MHC-B",
                    sampleCount: 2,
                    totalUniqueReads: 267,
                    sampleReads: ["DW472": 148, "DW474": 119],
                    rowStyle: GenotypeResultHighlightStyle(),
                    cellStyles: [:]
                )
            ]
        )

        let exportURL = root.appendingPathComponent("export.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(
            envelope.options.resolvedDefaults["visibleSampleIds"],
            .array([.string("DW472"), .string("DW474")])
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["visibleSampleCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["activeSmartCohortName"], .string("Filter: MHC-B"))
        XCTAssertEqual(envelope.options.resolvedDefaults["activeSmartCohortPredicate"], .string("textContains(MHC-B)"))
    }

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
}
