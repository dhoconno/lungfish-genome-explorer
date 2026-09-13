import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishGenotypeUI

/// Opt-in, whole-project acceptance: only disposable clones reach loaders and writers.
@MainActor
enum GenotypeThreeSheetCohortAcceptance {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LUNGFISH_EXCEL_QA_BUNDLE"], let project = env["LUNGFISH_EXCEL_QA_PROJECT"] else {
            throw XCTSkip("Set disposable whole-project LUNGFISH_EXCEL_QA_PROJECT and LUNGFISH_EXCEL_QA_BUNDLE")
        }
        let source = URL(fileURLWithPath: project).standardizedFileURL
        let input = URL(fileURLWithPath: path).standardizedFileURL
        guard input.path.hasPrefix(source.path + "/") else { throw NSError(domain: "QA input outside project", code: 1) }
        let before = try witness(source)
        defer { XCTAssertEqual(try? witness(source), before) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LGE-OneWay-Acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("working.lungfish")
        try FileManager.default.copyItem(at: source, to: copy)
        let bundle = copy.appendingPathComponent(String(input.path.dropFirst(source.path.count + 1)))
        let python = URL(fileURLWithPath: env["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = workspace.appendingPathComponent(".build/debug/lungfish-cli")
        let version = try LungfishCLIRunner.run(arguments: ["--version"], executableURL: cli)
        XCTAssertEqual(version.status, 0)
        try JSONSerialization.data(withJSONObject: ["executable": cli.path, "version": version.stdout,
            "sha256": ProvenanceFileHasher.sha256(of: cli)], options: [.sortedKeys]).write(to: root.appendingPathComponent("cli-witness.json"))
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let rawCalls = result.calls
        let oracleURL = root.appendingPathComponent("raw-evidence-oracle.json")
        try JSONEncoder().encode(GenotypeFullCurrentEvidenceOracle.capture(result)).write(to: oracleURL)
        let controller = GenotypeResultViewController(); _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
        let original = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        let initial = try capture(controller)
        let row = try XCTUnwrap(initial.allMatrix.rows.first { row in
            row.cells.contains { $0.reviewEligible && ($0.rawSupport ?? 0) > 0 && $0.review == nil && $0.comment == nil }
        })
        let cell = try XCTUnwrap(row.cells.first { $0.reviewEligible && ($0.rawSupport ?? 0) > 0 && $0.review == nil && $0.comment == nil })
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: row.target.locus,
            genotype: row.target.genotype, sample: cell.sampleID, stableClusterID: row.target.stableClusterID)
        for phase in ["initial", "set", "clear"] {
            if phase != "initial" {
                controller.applyMatrixReview(.init(targets: [target], intent: phase == "set" ? .set(.falsePositive) : .clear))
                controller.editMatrixComment(.init(targets: [target], intent: phase == "set" ? .upsert(body: "QA native cell comment") : .remove))
            }
            let snapshot = try capture(controller)
            let exported = try await GenotypeExcelExportService(pythonExecutableURL: python, replayExecutableURL: cli).export(
                snapshot: snapshot, outputURL: root.appendingPathComponent(phase + ".xlsx"),
                provenance: .init(workflowName: "cohort-one-way-acceptance", toolVersion: version.stdout,
                    argv: [cli.path, "genotype", "export"], options: ["phase": phase]))
            print(try runPython(python, script: GenotypeFullCurrentEvidenceOracle.pythonScript + "\n" + #"""
import json,sys,hashlib
from openpyxl import load_workbook
oracle=json.load(open(sys.argv[1])); snapshot=json.load(open(sys.argv[2]))
w=load_workbook(sys.argv[3],data_only=False)
print(verify_full_current_evidence(oracle,snapshot,w))
assert w.sheetnames==(['Haplotype Calls'] if snapshot['hasHaplotypeContent'] else [])+['Genotype Matrix - All','Genotype Matrix - Filtered','Export Metadata']
assert all(any((c.get('displayValue') or 0)>0 for c in r['cells']) for r in snapshot['filteredMatrix']['rows'])
receipt=json.load(open(sys.argv[3]+'.provenance.json'))
for name in ['output','snapshot','script','request','replayScript']:
    d=receipt[name]; data=open(d['path'],'rb').read()
    assert len(data)==d['sizeBytes'] and hashlib.sha256(data).hexdigest()==d['sha256']
assert receipt['executedArgv'] and receipt['durableReplayArgv'] and receipt['exitStatus']==0
"""#, arguments: [oracleURL.path, exported.snapshotURL.path, exported.outputURL.path]))
            let reopened = GenotypeResultViewController(); _ = reopened.view
            reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: bundle))
            reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
            let recaptured = try capture(reopened)
            XCTAssertEqual(try JSONEncoder().encode(recaptured.calls), try JSONEncoder().encode(snapshot.calls))
            XCTAssertEqual(try JSONEncoder().encode(recaptured.allMatrix), try JSONEncoder().encode(snapshot.allMatrix))
            XCTAssertEqual(try ONTGenotypeResultBundle.loadResult(from: bundle).calls, rawCalls)
        }
        let final = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        XCTAssertEqual(final.matrixReviews, original.matrixReviews)
        XCTAssertEqual(final.matrixComments, original.matrixComments)
        print("One-way cohort QA retained artifacts: \(root.path)")
    }

    private static func capture(_ controller: GenotypeResultViewController) throws -> GenotypeWorkbookPresentation.Snapshot {
        try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(controller.captureExcelExportSnapshot().excelSnapshotData))
    }

    private static func witness(_ root: URL) throws -> [String: String] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: String] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }

    private static func runPython(_ python: URL, script: String, arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = python; process.arguments = ["-c", script] + arguments
        let output = Pipe(); let error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errors = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ThreeSheetCohortQA", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self)
    }

}
