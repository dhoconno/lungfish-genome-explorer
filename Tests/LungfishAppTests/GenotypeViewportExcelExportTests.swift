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
        XCTAssertEqual(payload["evidenceColumn"] as? [String], ["AnimalA: 100 / 100"])
        XCTAssertEqual(payload["allRows"] as? Int, 2)
        XCTAssertEqual(payload["bands"] as? [[String]], [["M1A", "M1A"], ["M1A", "M1A"]])
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: String])
        XCTAssertEqual(metadata["minimumSupportPercent"], "7.5")
        XCTAssertEqual(metadata["supportDenominator"], "Sample Retained")
        XCTAssertEqual(metadata["matrixMinimumPercent"], "0.0")
        XCTAssertEqual(metadata["matrixPercentDenominator"], "Source Locus")
        XCTAssertEqual(payload["formulaCount"] as? Int, 0)

        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.provenanceURL)) as? [String: Any])
        XCTAssertEqual(receipt["workflowName"] as? String, "genotype.export.excel")
        XCTAssertEqual(receipt["toolVersion"] as? String, LungfishAppVersion.short)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        // The capture holds the sidecar the viewer showed. The comment edited
        // after the capture is in the bundle's file and not in the capture, so
        // the record says the file differs and never calls the capture the file.
        let receiptOptions = try XCTUnwrap(receipt["options"] as? [String: String])
        XCTAssertEqual(
            receiptOptions["annotationsSource"],
            "the sidecar the viewer held at capture, not read from the bundle's annotations.json"
        )
        XCTAssertEqual(
            receiptOptions["annotationsInBundle"],
            "annotations.json differs from the captured sidecar"
        )
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

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeViewportExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
# Locate columns by the table header (the last 'Stable ID' row), never by a
# fixed position: the native matrix decides which presentation columns exist.
def table_header(sheet):
    return [r for r in sheet.iter_rows() if r[0].value=='Stable ID'][-1]
header=table_header(matrix)
columns={c.value:c.column-1 for c in header}
sample=p['filteredMatrix']['samples'][0]['name']
evidence={r[0].value:r for r in matrix.iter_rows(min_row=header[0].row+1) if r[0].value in {x['id'] for x in p['filteredMatrix']['rows']}}
assert len(evidence)==len(p['filteredMatrix']['rows'])
for r in p['filteredMatrix']['rows']: assert evidence[r['id']][columns['Genotype']].value==r['target']['genotype']
def band_values(sheet):
    top=table_header(sheet)
    first=[c.column-1 for c in top if c.value==sample][0]
    return [r[first].value for r in sheet.iter_rows(max_row=top[0].row-1)
            if isinstance(r[1].value,str) and r[1].value.split(' ')[-1] in ('H1','H2')]
bands=[band_values(wb[n]) for n in ['Genotype Matrix - All','Genotype Matrix - Filtered']]
all_ids={r['id'] for r in p['allMatrix']['rows']}
out=dict(sheets=wb.sheetnames,call=[str(calls.cell(2,headers[f]).value or '') for f in fields],
 matrixRows=[[r['target']['genotype'],r['target']['locus'],r['target'].get('stableClusterID') or '',str(evidence[r['id']][columns[sample]].value)] for r in p['filteredMatrix']['rows']],
 evidenceColumn=[str(evidence[r['id']][columns['Evidence (display / raw support)']].value) for r in p['filteredMatrix']['rows']],
 allRows=sum(r[0].value in all_ids for r in wb['Genotype Matrix - All']),bands=bands,
 metadata={str(r[0].value or ''):str(r[1].value or '') for r in wb['Export Metadata']},
 formulaCount=sum(c.data_type=='f' for s in wb for row in s for c in row))
print(json.dumps(out))
"""#
}
