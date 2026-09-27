import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerSchemeFromAnalysisServiceTests: XCTestCase {
    private var root: URL!
    private var projectURL: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory
        let canonical = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
        root = canonical.appendingPathComponent("PrimerSchemeFromAnalysis-\(UUID().uuidString)", isDirectory: true)
        projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: PrimalScheme3 (native BED on the first alignment row)

    func testPrimalSchemeExportUsesOriginalRowHeaderAndFoldsVariantPrimers() throws {
        let fixture = try makePrimalSchemeBundle()
        let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: fixture.bundle)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertNil(candidate.refusalReason)
        XCTAssertEqual(candidate.engine, "PrimalScheme3")
        XCTAssertEqual(candidate.referenceID, "Mamu-A1_001")
        XCTAssertEqual(candidate.primerCount, 3)
        XCTAssertEqual(candidate.ampliconCount, 1)
        XCTAssertEqual(candidate.poolCount, 1)
        XCTAssertTrue(candidate.referenceStatement.contains("first row"), candidate.referenceStatement)

        let result = try PrimerSchemeFromAnalysisService.export(request: .init(
            analysisURL: fixture.bundle, resultID: nil, outputURL: URL(fileURLWithPath: "MHC design"),
            projectURL: projectURL, displayName: nil, argv: ["lungfish", "primers", "scheme-from-analysis"],
            workflowName: "lungfish primers scheme-from-analysis", toolVersion: "test"))
        XCTAssertEqual(result.bundleURL.deletingLastPathComponent().lastPathComponent, PrimerSchemesFolder.folderName)
        XCTAssertEqual(result.bundleURL.lastPathComponent, "MHC design.lungfishprimers")

        let bundle = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(bundle.manifest.canonicalAccession, "Mamu-A1_001")
        XCTAssertEqual(bundle.manifest.equivalentAccessions, [fixture.normalizedReference])
        XCTAssertEqual(bundle.manifest.primerCount, 3)
        XCTAssertEqual(bundle.manifest.ampliconCount, 1)
        XCTAssertEqual(bundle.manifest.source, "designed")
        XCTAssertTrue(bundle.manifest.description?.contains("PrimalScheme3") == true, bundle.manifest.description ?? "")
        let bed = try String(contentsOf: bundle.bedURL, encoding: .utf8)
        let rows = bed.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("Mamu-A1_001\t") }, bed)
        XCTAssertTrue(bed.contains("Mamu-A1_001\t2\t5\tfx_1_LEFT_1\t1\t+\tCCG"), bed)
        XCTAssertTrue(bed.contains("Mamu-A1_001\t9\t12\tfx_1_RIGHT_1\t1\t-\tGGT"), bed)
        let primers = try String(contentsOf: try XCTUnwrap(bundle.fastaURL), encoding: .utf8)
        XCTAssertEqual(primers.filter { $0 == ">" }.count, 3)

        let attachment = result.bundleURL.appendingPathComponent("attachments/design-reference.fasta")
        let reference = try String(contentsOf: attachment, encoding: .utf8)
        XCTAssertEqual(reference, ">Mamu-A1_001\nAACCGGTTAACCGGTT\n")
        XCTAssertEqual(bundle.manifest.attachments?.map(\.path), ["attachments/design-reference.fasta"])
        let provenance = try String(contentsOf: bundle.provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("Source analysis: \(fixture.bundle.path)"), provenance)
        XCTAssertTrue(provenance.contains("Coordinate reference: Mamu-A1_001"), provenance)
    }

    func testPrimalSchemeCombinedPanelAcrossReferencesIsRefused() throws {
        let fixture = try makePrimalSchemeBundle(references: 2)
        let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: fixture.bundle)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].refusalReason?.contains("2 references") == true, candidates[0].refusalReason ?? "")
        XCTAssertThrowsError(try PrimerSchemeFromAnalysisService.export(request: .init(
            analysisURL: fixture.bundle, resultID: nil, outputURL: URL(fileURLWithPath: "refused"),
            projectURL: projectURL, displayName: nil, argv: ["test"], workflowName: "test", toolVersion: "test")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("Primer Schemes/refused.lungfishprimers").path))
    }

    // MARK: varVAMP and Olivar (normalized results on a generated reference)

    func testVarVAMPTiledExportIncludesGeneratedReferenceAndNativePools() async throws {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: .tiled)
            return fixture.execution(for: command)
        }
        let analysis = try await pipeline.run(request: fixture.request(options: fixture.tiledOptions))

        let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: analysis)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertNil(candidate.refusalReason)
        XCTAssertEqual(candidate.engine, "varVAMP")
        XCTAssertEqual(candidate.referenceID, "generated-ref")
        XCTAssertTrue(candidate.referenceStatement.contains("ambiguous consensus"), candidate.referenceStatement)

        let result = try PrimerSchemeFromAnalysisService.export(request: .init(
            analysisURL: analysis, resultID: candidate.resultID, outputURL: URL(fileURLWithPath: "varvamp-tiled"),
            projectURL: projectURL, displayName: "varVAMP tiled", argv: ["test"],
            workflowName: "lungfish primers scheme-from-analysis", toolVersion: "test"))
        let bundle = try PrimerSchemeBundle.load(from: result.bundleURL)
        XCTAssertEqual(bundle.manifest.canonicalAccession, "generated-ref")
        XCTAssertEqual(bundle.manifest.equivalentAccessions, [])
        XCTAssertEqual(bundle.manifest.displayName, "varVAMP tiled")
        XCTAssertEqual(bundle.manifest.primerCount, 2)
        XCTAssertEqual(bundle.manifest.ampliconCount, 1)
        let bed = try String(contentsOf: bundle.bedURL, encoding: .utf8)
        XCTAssertEqual(bed, "generated-ref\t10\t20\tLEFT_1\t1\t+\tACGTACGTAC\ngenerated-ref\t80\t90\tRIGHT_1\t1\t-\tTGCATGCATG\n")
        let reference = try String(contentsOf: result.bundleURL.appendingPathComponent("attachments/design-reference.fasta"), encoding: .utf8)
        XCTAssertEqual(reference, ">generated-ref\n" + String(repeating: "ACGT", count: 25) + "\n")
    }

    func testVarVAMPQPCRResultIsRefusedBecauseItIsNotATiledScheme() async throws {
        let fixture = try PrimerSchemePipelineFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: .qpcr, includeProbe: true)
            return fixture.execution(for: command)
        }
        let analysis = try await pipeline.run(request: fixture.request(options: fixture.qpcrOptions))
        let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: analysis)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].refusalReason?.contains("qPCR") == true, candidates[0].refusalReason ?? "")
    }

    func testPrimer3AnalysisHasNoExportableScheme() throws {
        let bundle = try makePrimer3Bundle()
        let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: bundle)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertThrowsError(try PrimerSchemeFromAnalysisService.export(request: .init(
            analysisURL: bundle, resultID: nil, outputURL: URL(fileURLWithPath: "none"),
            projectURL: projectURL, displayName: nil, argv: ["test"], workflowName: "test", toolVersion: "test"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Primer3"), error.localizedDescription)
        }
    }

    // MARK: Fixtures

    private struct PrimalSchemeFixture {
        let bundle: URL
        let normalizedReference: String
    }

    private func makePrimalSchemeBundle(references: Int = 1) throws -> PrimalSchemeFixture {
        let inputID = UUID(), resultID = UUID()
        let hex = inputID.uuidString.replacingOccurrences(of: "-", with: "")
        let row0 = "input_\(hex)_row_0", row1 = "input_\(hex)_row_1"
        var payloads: [String: String] = [
            "inputs/\(inputID.uuidString).fasta": ">\(row0)\nAACC-GGTTAACCGGTT\n>\(row1)\nAACCTGGTTAACCGGTT\n",
            "inputs/\(inputID.uuidString)-row-map.json": """
            {"schemaVersion":1,"inputID":"\(inputID.uuidString)","rows":[
            {"rowIndex":0,"originalHeader":"Mamu-A1_001 first allele","normalizedHeader":"\(row0)"},
            {"rowIndex":1,"originalHeader":"Mamu-A1_002","normalizedHeader":"\(row1)"}]}
            """,
        ]
        var reference = ">\(row0)\nAACCGGTTAACCGGTT\n"
        var bed = "# artic-bed-version v3.0\n\(row0)\t2\t5\tfx_1_LEFT_1\t1\t+\tCCG\n\(row0)\t1\t5\tfx_1_LEFT_2\t1\t+\tACCG\n\(row0)\t9\t12\tfx_1_RIGHT_1\t1\t-\tGGT\n"
        var amplicons = "\(row0)\t1\t12\tfx_1\t1\n"
        if references == 2 {
            reference += ">other_ref\nAACCGGTTAACCGGTT\n"
            bed += "other_ref\t2\t5\tfx_2_LEFT_1\t2\t+\tCCG\nother_ref\t9\t12\tfx_2_RIGHT_1\t2\t-\tGGT\n"
            amplicons += "other_ref\t2\t12\tfx_2\t2\n"
        }
        let native = "native/\(resultID.uuidString)/"
        payloads[native + "reference.fasta"] = reference
        payloads[native + "primer.bed"] = bed
        payloads[native + "amplicon.bed"] = amplicons
        let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
            let source = root.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: source)
            return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
                role: path.hasPrefix("inputs/") ? "input" : "nativeOutput",
                format: path.hasSuffix(".bed") ? "bed" : path.hasSuffix(".json") ? "json" : "fasta")
        }
        let written = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: inputID, label: "Mamu-A1.lungfishmsa",
                artifactPaths: payloads.keys.filter { $0.hasPrefix("inputs/") }.sorted())],
            results: [.init(id: resultID, label: "Mamu-A1", inputIDs: [inputID],
                artifactPaths: payloads.keys.filter { $0.hasPrefix(native) }.sorted())],
            artifacts: artifacts,
            destinationURL: root.appendingPathComponent("primalscheme.lungfishprimeranalysis"),
            invocation: .init(argv: ["fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return .init(bundle: written.url, normalizedReference: row0)
    }

    private func makePrimer3Bundle() throws -> URL {
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let input = root.appendingPathComponent("input.fasta")
        try Data(">t\nACGTACGT\n".utf8).write(to: input)
        let document: [String: Any] = [
            "schemaVersion": 1, "analysisID": analysisID.uuidString, "runID": runID.uuidString,
            "results": [[
                "resultID": resultID.uuidString, "inputID": inputID.uuidString, "title": "t",
                "sourceKind": "fasta", "sourceIndex": 0, "sourceRecordID": "t",
                "templateSequence": "ACGTACGT", "excludedRegions": [],
                "pairs": [[
                    "id": UUID().uuidString, "productSize": 8,
                    "left": ["id": UUID().uuidString, "start": 0, "end": 2, "orientation": "forward",
                             "sequence": "AC", "meltingTemperature": 60.0, "gcPercent": 50.0],
                    "right": ["id": UUID().uuidString, "start": 6, "end": 8, "orientation": "reverse",
                              "sequence": "AC", "meltingTemperature": 60.0, "gcPercent": 50.0],
                ]],
            ]],
        ]
        let normalized = root.appendingPathComponent("normalized.json")
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
        let native = root.appendingPathComponent("native.txt")
        try Data("fixture\n".utf8).write(to: native)
        let path = "results/primer3-normalized-v1.json"
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
            analysisID: analysisID, runID: runID, grouping: .independent,
            inputs: [.init(id: inputID, label: "t", artifactPaths: ["inputs/input.fasta"])],
            results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
            artifacts: [
                .init(sourceURL: input, relativePath: "inputs/input.fasta", role: "input", format: "fasta"),
                .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
                .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
            ], destinationURL: root.appendingPathComponent("primer3.lungfishprimeranalysis"),
            invocation: .init(argv: ["fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return bundle.url
    }
}
