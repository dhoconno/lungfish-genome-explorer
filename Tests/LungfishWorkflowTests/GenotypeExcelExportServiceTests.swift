import Foundation
import CryptoKit
import LungfishCore
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class GenotypeExcelExportServiceTests: XCTestCase {
    private let timestamp = "2026-09-12T12:00:00Z"
    private var python: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
    }
    private var cli: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_CLI"] ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/lungfish-cli").path)
    }

    func testServicePublishesThreeSheetReportAndDurableReplayWithExactWitnesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-excel-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.json")
        let inputBytes = Data("captured input".utf8)
        try inputBytes.write(to: input)
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "=1+1", genotype: "Mafa-A*001", reads: 1)])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumReads: 5))
        let output = root.appendingPathComponent("report.xlsx")
        let exported = try await GenotypeExcelExportService(pythonExecutableURL: python, replayExecutableURL: cli).export(snapshot: snapshot,
            outputURL: output, provenance: .init(toolVersion: "test-version", argv: ["lungfish-cli", "genotype", "export-xlsx"],
                options: ["output": output.path], defaults: ["minimumReads": "0"],
                runtimeContext: ["condaEnvironment": "openpyxl"], inputs: [.init(path: input.path, data: inputBytes)]))
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.receiptURL)) as? [String: Any])
        let artifact = try XCTUnwrap(receipt["output"] as? [String: Any])
        XCTAssertEqual(artifact["path"] as? String, output.path)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(artifact["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(artifact["sizeBytes"] as? Int, bytes.count)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.snapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.replayScriptURL.path))
        let inspection = try inspect(output)
        XCTAssertEqual(inspection["sheets"] as? [String], ["Genotype Matrix - All", "Genotype Matrix - Filtered", "Export Metadata"])
        XCTAssertEqual(inspection["formulas"] as? Int, 0)
        let values = try XCTUnwrap(inspection["matrixD2"] as? [String: Any])
        XCTAssertEqual(values["Genotype Matrix - All"] as? Int, 1)
        XCTAssertTrue(values["Genotype Matrix - Filtered"] is NSNull)
        XCTAssertFalse((inspection["filteredLabels"] as? [String] ?? []).contains("Mafa-A*001"))
        XCTAssertTrue((inspection["strings"] as? [String])?.contains("=1+1") == true)
        let replay = root.appendingPathComponent("replayed.xlsx")
        var replayArgv = try XCTUnwrap(receipt["durableReplayArgv"] as? [String])
        // Replay consumes the frozen capture, not mutable/temporary originals.
        try Data("changed since capture".utf8).write(to: input)
        XCTAssertEqual(try runCommand(replayArgv), 0)
        try assertReceipt(for: output, expectedArgv: replayArgv)
        try FileManager.default.removeItem(at: input)
        let outputIndex = try XCTUnwrap(replayArgv.firstIndex(of: "--output")) + 1
        replayArgv[outputIndex] = replay.path
        XCTAssertEqual(try runCommand(replayArgv), 0)
        try assertReceipt(for: replay, expectedArgv: replayArgv)
        XCTAssertEqual(try inspect(replay)["sheets"] as? [String], inspection["sheets"] as? [String])
        let previousOutput = try Data(contentsOf: replay), previousReceipt = try Data(contentsOf: replay.appendingPathExtension("provenance.json"))
        var failedArgv = replayArgv
        failedArgv[try XCTUnwrap(failedArgv.firstIndex(of: "--python")) + 1] = "/usr/bin/false"
        XCTAssertNotEqual(try runCommand(failedArgv), 0)
        XCTAssertEqual(try Data(contentsOf: replay), previousOutput)
        XCTAssertEqual(try Data(contentsOf: replay.appendingPathExtension("provenance.json")), previousReceipt)
        let scriptOutput = root.appendingPathComponent("script-replayed.xlsx")
        XCTAssertEqual(try runCommand(["/bin/sh", exported.replayScriptURL.path, scriptOutput.path]), 0)
        try assertReceipt(for: scriptOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        print("Retained one-way workbook QA: \(output.path)")
    }

    func testChangedInputAndRendererFailurePreservePreviousOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-excel-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try Data("new".utf8).write(to: input)
        let output = root.appendingPathComponent("report.xlsx")
        let old = Data("previous successful report".utf8)
        try old.write(to: output)
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp)
        do {
            _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot, outputURL: output,
                provenance: .init(toolVersion: "test", argv: ["test"], inputs: [.init(path: input.path, data: Data("old".utf8))]))
            XCTFail("changed witnessed input was accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), old)
        do {
            _ = try await GenotypeExcelExportService(pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/false")).export(
                snapshot: snapshot, outputURL: output, provenance: .init(toolVersion: "test", argv: ["test"]))
            XCTFail("failed renderer was accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), old)
    }

    func testSnapshotCLIRequiresOneSourceAndExplicitReplayInputs() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lge-invalid-replay-\(UUID().uuidString).xlsx")
        for options in [[], ["--bundle", "bundle", "--snapshot", "snapshot"],
                        ["--snapshot", "snapshot"], ["--snapshot", "snapshot", "--python", python.path],
                        ["--bundle", "bundle", "--provenance-request", "request"]] {
            XCTAssertNotEqual(try runCommand([cli.path, "genotype", "export-xlsx", "--output", output.path] + options), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    private func runCommand(_ argv: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: argv[0]); process.arguments = Array(argv.dropFirst())
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 { print(String(data: data, encoding: .utf8) ?? "") }
        return process.terminationStatus
    }

    private func assertReceipt(for output: URL, expectedArgv: [String]? = nil) throws {
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathExtension("provenance.json"))) as? [String: Any])
        let descriptor = try XCTUnwrap(receipt["output"] as? [String: Any])
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(descriptor["path"] as? String, output.path)
        XCTAssertEqual(descriptor["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(descriptor["sizeBytes"] as? Int, bytes.count)
        XCTAssertEqual(receipt["workflowName"] as? String, "genotype.export.excel.replay")
        XCTAssertEqual(receipt["toolVersion"] as? String, LungfishAppVersion.short)
        if let expectedArgv { XCTAssertEqual(receipt["argv"] as? [String], expectedArgv) }
        XCTAssertEqual((receipt["options"] as? [String: String])?["output"], output.path)
    }

    private func inspect(_ output: URL) throws -> [String: Any] {
        let process = Process(); process.executableURL = python
        process.arguments = ["-c", #"""
import openpyxl,json,sys
w=openpyxl.load_workbook(sys.argv[1])
cells=[c for s in w for row in s for c in row]
def fill(c):
    return c.fill.fgColor.rgb[-6:] if c.fill.patternType == 'solid' and c.fill.fgColor.type == 'rgb' else ''
calls=[]
if 'Haplotype Calls' in w:
    for r in list(w['Haplotype Calls'])[1:]:
        calls.append(dict(values=[c.value or '' for c in r[3:9]], fills=[fill(c) for c in r[3:5]]))
bands={s.title:[dict(slot=r[2].value,value=r[3].value or '',fill=fill(r[3]),comment=r[3].comment.text if r[3].comment else '') for r in s if len(r)>3 and r[2].value in ('H1','H2')] for s in w if s.title.startswith('Genotype Matrix')}
print(json.dumps(dict(sheets=w.sheetnames,formulas=sum(c.data_type=='f' for c in cells),strings=[c.value for c in cells if isinstance(c.value,str)],matrixD2={s.title:s['D2'].value for s in w if s.title.startswith('Genotype Matrix')},filteredLabels=[r[2].value for r in w['Genotype Matrix - Filtered'] if len(r)>2 and isinstance(r[2].value,str)],calls=calls,bands=bands)))
"""#, output.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertWorkbookCalls(_ inspection: [String: Any], values: [String], fills: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let calls = try XCTUnwrap(inspection["calls"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(calls.count, 1, file: file, line: line)
        XCTAssertEqual(calls.first?["values"] as? [String], values, file: file, line: line)
        XCTAssertEqual(calls.first?["fills"] as? [String], fills, file: file, line: line)
        let bands = try XCTUnwrap(inspection["bands"] as? [String: [[String: String]]], file: file, line: line)
        for title in ["Genotype Matrix - All", "Genotype Matrix - Filtered"] {
            let slots = try XCTUnwrap(bands[title], file: file, line: line)
            XCTAssertEqual(slots.map { $0["slot"] ?? "" }, ["H1", "H2"], file: file, line: line)
            XCTAssertEqual(slots.map { $0["value"] ?? "" }, Array(values.prefix(2)), file: file, line: line)
            XCTAssertEqual(slots.map { $0["fill"] ?? "" }, fills, file: file, line: line)
            for (index, slot) in slots.enumerated() {
                XCTAssertEqual(slot["comment"], "Haplotype slot: H\(index + 1)\nStatus: \(values[index + 2])\nSource: \(values[index + 4])", file: file, line: line)
            }
        }
    }

    func testGenotypeOnlyCaptureKeepsRawSupportAndExactViewportMask() throws {
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1),
        ])
        let projection = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [
            .init(label: "Mafa-A*001", locus: result.calls[0].locusGroup, cells: [""]),
        ])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: "2026-09-12"),
            allProjection: nil, filteredProjection: projection, generatedAt: "2026-09-12T12:00:00Z")
        XCTAssertFalse(snapshot.hasHaplotypeContent)
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.displayValue, 1)
        XCTAssertTrue(snapshot.filteredMatrix.rows.isEmpty)
    }

    func testCaptureRejectsInventedViewportEvidence() throws {
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1),
        ])
        let projection = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [
            .init(label: "Mafa-A*001", locus: result.calls[0].locusGroup, cells: ["90"]),
        ])
        XCTAssertThrowsError(try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: "2026-09-12"),
            allProjection: nil, filteredProjection: projection, generatedAt: "2026-09-12T12:00:00Z"))
    }

    func testNativeDuplicateOccurrenceAndDenominatorsSurviveCapture() throws {
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 4, retainedReads: 40),
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 16, retainedReads: 1000),
        ])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: nil), filter: .init(matrixMinimumPercent: 5, matrixDenominator: .sampleRetained))
        // Native cells use the highest retained occurrence. Filtering is per
        // occurrence: 4/40 passes 5%; 16/1000 fails. Review raw remains 16.
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.displayValue, 16)
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.rawSupport, 16)
        XCTAssertEqual(snapshot.filteredMatrix.rows.first?.cells.first?.displayValue, 4)
    }

    func testCatalogIdentityExactZeroDuplicateLabelsAndStyleClearing() throws {
        let catalog = GenotypeReviewableRowCatalog(schemaID: GenotypeReviewableRowCatalog.schemaID, schemaVersion: 1,
            samples: ["S1", "S2"], rows: [
                .init(kind: .candidate, callID: "catalog-A", displayName: "same-label", locus: "MHC-A", stableID: "A",
                    section: "candidate", sortKey: "A", supportBySample: ["S1": 0, "S2": 7]),
                .init(kind: .candidate, callID: "catalog-B", displayName: "same-label", locus: "MHC-A", stableID: "B",
                    section: "candidate", sortKey: "B", supportBySample: ["S1": 0, "S2": 9]),
            ])
        let result = GenotypeTestFixtures.makeResult(calls: [], reviewableRowCatalog: catalog)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: "same-label", sample: "S1", stableClusterID: "B")
        sidecar.matrixReviews = [.init(target: target, disposition: .falseNegative, author: "Tester", timestamp: timestamp)]
        sidecar.matrixComments = [.init(target: target, body: "=literal note", author: "Tester", timestamp: timestamp)]
        sidecar.matrixStyles = [
            .init(target: .row(locus: "MHC-A", genotype: "same-label"), style: .init(isBold: true), author: "Tester", timestamp: timestamp),
            .init(target: target, style: .init(boldOverride: false), author: "Tester", timestamp: timestamp),
        ]
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertEqual(snapshot.allMatrix.rows.count, 2)
        XCTAssertEqual(Set(snapshot.allMatrix.rows.map(\.id)).count, 2)
        let row = try XCTUnwrap(snapshot.allMatrix.rows.first { $0.target.stableClusterID == "B" })
        XCTAssertEqual(row.cells[0].rawSupport, 0)
        XCTAssertEqual(row.cells[0].review, "false-negative")
        XCTAssertEqual(row.cells[0].comment, "=literal note")
        XCTAssertEqual(row.style?.isBold, true)
        XCTAssertEqual(row.cells[0].style?.isBold, false)
        XCTAssertEqual(try JSONDecoder().decode(GenotypeAnnotationSidecar.self,
            from: XCTUnwrap(snapshot.capturedScientificInputs?["annotations.json"])), sidecar)
        let percentFiltered = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumPercent: 60, matrixDenominator: .sampleRetained))
        // Both candidates have one positive supporting sample among two (50%).
        XCTAssertEqual(percentFiltered.allMatrix.rows.count, 2)
        XCTAssertTrue(percentFiltered.filteredMatrix.rows.isEmpty)
    }

    func testManualCallContentIsFullScopeAndNeverInventsSecondSlot() async throws {
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1)],
            kind: "miseq-amplicon-mhc-genotype")
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.manualHaplotypeAssignments = [.init(sample: "S1", locus: "MHC-A", slot: .h1, label: "=1+1",
            colorTokenIndex: 4, diagnosticAlleles: [], notes: "manual")]
        let projection = GenotypeViewProjection(lens: "genotype", sampleColumns: [], rows: [])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: projection, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertTrue(snapshot.hasHaplotypeContent)
        XCTAssertEqual(snapshot.calls.first?.h1.effective, "=1+1")
        XCTAssertEqual(snapshot.calls.first?.h2.effective, "")
        XCTAssertEqual(snapshot.calls.first?.h2.baselineAvailable, false)
        XCTAssertEqual(snapshot.colors.first?.fillHex.uppercased(), "#008000")
        let visible = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: .init(lens: "genotype", sampleColumns: ["S1"], rows: []),
            generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertTrue(visible.filteredMatrix.rows.isEmpty)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lge-manual-\(UUID().uuidString).xlsx")
        _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: visible, outputURL: output,
            provenance: .init(toolVersion: "test", argv: ["test"]))
        let inspection = try inspect(output)
        XCTAssertEqual(inspection["sheets"] as? [String], ["Haplotype Calls", "Genotype Matrix - All", "Genotype Matrix - Filtered", "Export Metadata"])
        try assertWorkbookCalls(inspection, values: ["=1+1", "", "called", "unassigned", "manualAssignment", "unassigned"], fills: ["008000", ""])
        print("Retained manual QA: \(output.path)")
    }

    func testHomozygoteAndAnalyzedUnresolvedKeepCommonCallAuthority() async throws {
        for status in [GenotypeHaplotypeCallStatus.called, .noHaplotype] {
            let analysis = GenotypeHaplotypeAnalysis(assayID: "fixture", definitionSetID: "fixture", definitionSetName: "fixture",
                speciesName: "fixture", samples: [.init(sample: "S1", calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                    haplotype1: status == .called ? "M4" : "", haplotype2: "", status: status,
                    matchedHaplotypes: [], observedGenotypeCount: 0, observedGenotypes: [])])])
            let result = GenotypeTestFixtures.makeResult(calls: [], haplotypeAnalysis: analysis)
            let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
                allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: analysis))
            XCTAssertTrue(snapshot.hasHaplotypeContent)
            XCTAssertEqual(snapshot.calls.first?.h2.effective, status == .called ? "M4" : "")
            XCTAssertEqual(snapshot.calls.first?.h2.pipeline, "")
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("lge-\(status.rawValue)-\(UUID().uuidString).xlsx")
            _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot, outputURL: output,
                provenance: .init(toolVersion: "test", argv: ["test"]))
            let inspection = try inspect(output)
            XCTAssertEqual((inspection["sheets"] as? [String])?.count, 4)
            let effective = status == .called ? "M4" : ""
            try assertWorkbookCalls(inspection, values: [effective, effective, status.rawValue, status.rawValue, "pipeline", "pipeline"],
                fills: status == .called ? ["008000", "008000"] : ["", ""])
            print("Retained automatic QA: \(output.path)")
        }
    }

    func testCaptureRejectsChangedCallProjectionAndIncompleteAllProjection() throws {
        let analysis = GenotypeHaplotypeAnalysis(assayID: "fixture", definitionSetID: "fixture", definitionSetName: "fixture",
            speciesName: "fixture", samples: [.init(sample: "S1", calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A",
                haplotype1: "M4", haplotype2: "", status: .called, matchedHaplotypes: [], observedGenotypeCount: 0, observedGenotypes: [])])])
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1)], haplotypeAnalysis: analysis)
        let changed = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [], haplotypeCalls: [
            .init(sample: "S1", locus: "MHC-A", haplotype1: "M1", haplotype2: "M1", haplotype1Status: "called",
                haplotype2Status: "called", haplotype1Source: "pipeline", haplotype2Source: "pipeline", baselineHaplotype1: "M4", baselineHaplotype2: "")])
        XCTAssertThrowsError(try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: changed, generatedAt: timestamp, authority: .init(analysis: analysis)))
        XCTAssertThrowsError(try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: .init(lens: "genotype", sampleColumns: ["S1"], rows: []), filteredProjection: nil,
            generatedAt: timestamp, authority: .init(analysis: analysis)))
    }

    func testProjectionLegacyColorAndCandidatePopulationThresholdsArePreserved() throws {
        let observations: [ONTMHCCandidateObservation] = [
            .init(stableClusterID: "A", sampleID: "S1", readGroupID: "a", sourceClusterIDs: ["a"], sourceClusterReadCounts: ["a": 2], aggregatedSampleReadCount: 2, evidence: []),
            .init(stableClusterID: "A", sampleID: "S1", readGroupID: "b", sourceClusterIDs: ["b"], sourceClusterReadCounts: ["b": 2], aggregatedSampleReadCount: 2, evidence: []),
            .init(stableClusterID: "A", sampleID: "S2", readGroupID: "c", sourceClusterIDs: ["c"], sourceClusterReadCounts: ["c": 9], aggregatedSampleReadCount: 9, evidence: []),
            .init(stableClusterID: "B", sampleID: "S3", readGroupID: "d", sourceClusterIDs: ["d"], sourceClusterReadCounts: ["d": 7], aggregatedSampleReadCount: 7, evidence: []),
        ]
        func candidate(_ id: String, _ samples: [String]) -> ONTMHCCandidateRecord {
            .init(stableClusterID: id, provisionalName: "same-label", locus: "MHC-A", classification: .novel,
                supportClass: samples.count > 1 ? .shared : .singleton, closestReferenceName: "reference", closestReferenceClass: .genomicDNA,
                snpCount: 1, insertedBases: 0, deletedBases: 0, longGapBases: 0, comparableBases: 2000, shorterCoverage: 1,
                identity: 0.99, mappingQuality: 60, alignmentScore: 2000, independentSampleCount: samples.count,
                occurrenceCount: samples.count, totalClusterReads: 20, supportingSampleIDs: samples, fastaRecordID: id,
                sequenceSHA256: String(repeating: "b", count: 64), selectedEvidence: .init(bamPath: "evidence.bam",
                    queryName: id, referenceName: "reference", readGroupID: nil, referenceStart: 1, cigar: "2000M"))
        }
        let document = ONTMHCCandidateAllelesDocument(schemaVersion: 1, createdAt: timestamp, thresholds: .defaults, inputs: [], evidence: [],
            sequenceFASTA: .init(path: "candidate.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            candidates: [candidate("A", ["S1", "S2"]), candidate("B", ["S3"])], observations: observations)
        let original = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "S4", genotype: "Mafa-A*001", reads: 1)])
        let result = ONTGenotypeResultBundleData(bundleURL: original.bundleURL, manifest: original.manifest, artifacts: original.artifacts,
            stats: original.stats, calls: original.calls, samples: original.samples, haplotypeAnalysis: nil,
            mhcCandidates: document, mhcUnnameableClusters: nil, mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty, mhcAlignmentArtifactURLs: .empty,
            mhcReferenceVisualizations: nil, integrityWarnings: [], referenceMetadata: nil,
            provisionalExon2SequencesByGenotype: [:], provisionalExon2ArtifactURLs: .empty, reviewableRowCatalog: nil)
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumReads: 8, matrixMinimumPercent: 30, matrixDenominator: .sampleRetained))
        XCTAssertEqual(snapshot.allMatrix.rows.filter { $0.target.stableClusterID != nil }.count, 2)
        XCTAssertEqual(snapshot.filteredMatrix.rows.count, 1)
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first)
        XCTAssertEqual(row.target.stableClusterID, "A")
        XCTAssertEqual(row.cells.first { $0.sampleID == "S1" }?.rawSupport, 4)
        XCTAssertNil(row.cells.first { $0.sampleID == "S1" }?.displayValue)
        XCTAssertEqual(row.cells.first { $0.sampleID == "S2" }?.displayValue, 9)
        let projection = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S4"], rows: [
            .init(label: "Mafa-A*001", locus: original.calls[0].locusGroup, cells: ["1"], cellColorsHex: ["#123456"], rowColorHex: "#ABCDEF")])
        let styled = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: projection, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertEqual(styled.filteredMatrix.rows.first?.style?.fillHex, "#ABCDEF")
        XCTAssertEqual(styled.filteredMatrix.rows.first?.cells.first?.style?.fillHex, "#123456")
    }

    func testCanonicalCatalogLocusAttestsNativeRowWithoutDuplicatingIt() throws {
        let candidate = ONTMHCCandidateRecord(stableClusterID: "A", provisionalName: "Mafa-A1*900:01_nov", locus: "MHC-A1", classification: .novel,
            supportClass: .singleton, closestReferenceName: "reference", closestReferenceClass: .genomicDNA,
            snpCount: 1, insertedBases: 0, deletedBases: 0, longGapBases: 0, comparableBases: 2000, shorterCoverage: 1,
            identity: 0.99, mappingQuality: 60, alignmentScore: 2000, independentSampleCount: 1,
            occurrenceCount: 1, totalClusterReads: 12, supportingSampleIDs: ["S1"], fastaRecordID: "A",
            sequenceSHA256: String(repeating: "b", count: 64), selectedEvidence: .init(bamPath: "evidence.bam",
                queryName: "A", referenceName: "reference", readGroupID: nil, referenceStart: 1, cigar: "2000M"))
        let document = ONTMHCCandidateAllelesDocument(schemaVersion: 1, createdAt: timestamp, thresholds: .defaults, inputs: [], evidence: [],
            sequenceFASTA: .init(path: "candidate.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1), candidates: [candidate], observations: [
                .init(stableClusterID: "A", sampleID: "S1", readGroupID: "a", sourceClusterIDs: ["a"], sourceClusterReadCounts: ["a": 12], aggregatedSampleReadCount: 12, evidence: [])])
        let catalog = GenotypeReviewableRowCatalog(schemaID: GenotypeReviewableRowCatalog.schemaID, schemaVersion: 1,
            samples: ["S1", "S2"], rows: [.init(kind: .candidate, callID: "candidate:MHC-A:A",
                displayName: "Mafa-A1*900:01_nov", locus: "MHC-A", stableID: "A", section: "candidate", sortKey: "A",
                supportBySample: ["S1": 12, "S2": 0])])
        let original = GenotypeTestFixtures.makeResult(calls: [])
        let result = ONTGenotypeResultBundleData(bundleURL: original.bundleURL, manifest: original.manifest, artifacts: original.artifacts,
            stats: original.stats, calls: [], samples: [], haplotypeAnalysis: nil,
            mhcCandidates: document, mhcUnnameableClusters: nil, mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty, mhcAlignmentArtifactURLs: .empty, mhcReferenceVisualizations: nil, integrityWarnings: [],
            referenceMetadata: nil, provisionalExon2SequencesByGenotype: [:], provisionalExon2ArtifactURLs: .empty, reviewableRowCatalog: catalog)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.matrixReviews = [.init(target: .cell(locus: "MHC-A1", genotype: "Mafa-A1*900:01_nov", sample: "S2", stableClusterID: "A"),
            disposition: .falseNegative, author: "Tester", timestamp: timestamp)]
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result,
            sidecar: sidecar, allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertEqual(snapshot.allMatrix.rows.count, 1)
        let row = try XCTUnwrap(snapshot.allMatrix.rows.first)
        XCTAssertEqual(row.target.locus, "MHC-A1")
        XCTAssertEqual(row.cells.first { $0.sampleID == "S2" }?.rawSupport, 0)
        XCTAssertEqual(row.cells.first { $0.sampleID == "S2" }?.review, "false-negative")
    }

    func testNoOverwritePolicyPreservesDestinationCreatedDuringRendering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-export-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("report.xlsx")
        let wrapper = root.appendingPathComponent("python-wrapper")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nprintf '%s' 'competing report' > \(quote(output.path))\nexec \(quote(python.path)) \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        do {
            _ = try await GenotypeExcelExportService(pythonExecutableURL: wrapper).export(snapshot: snapshot, outputURL: output,
                provenance: .init(toolVersion: "test", argv: ["test"]), replacingExisting: false)
            XCTFail("a competing report was overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "competing report")
    }

    func testProvenanceDestinationFailurePreservesExistingWorkbook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-export-receipt-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("report.xlsx")
        try Data("previous report".utf8).write(to: output)
        try FileManager.default.createDirectory(at: output.appendingPathExtension("provenance.json"), withIntermediateDirectories: false)
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        do {
            _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot, outputURL: output,
                provenance: .init(toolVersion: "test", argv: ["test"]))
            XCTFail("invalid receipt destination was accepted")
        } catch {}
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "previous report")
    }

    func testBuilderRejectsMismatchedFrozenDefinitionAuthority() throws {
        let analysis = GenotypeHaplotypeAnalysis(assayID: "A", definitionSetID: "one", definitionSetName: "one", speciesName: "fixture", samples: [])
        let definition = GenotypeHaplotypeDefinitionSet(id: "two", assayID: "A", displayName: "two", speciesName: "fixture", speciesCode: "F", prefix: "F", locusDefinitions: [])
        XCTAssertThrowsError(try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: [], haplotypeAnalysis: analysis),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: analysis, definitionSet: definition)))
    }

    func testCaptureRecordsAllFilterDefaultsAndFrozenOrdering() throws {
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: nil, locusDisplayOrder: ["MHC-B", "MHC-A"]),
            filter: .init(globalMinimumPercent: 2, globalDenominator: .sampleRetained, matrixMinimumReads: 5))
        let context = try XCTUnwrap(snapshot.capturedScientificInputs?["capture-context.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: context) as? [String: Any])
        XCTAssertEqual(object["filteredEvidenceRowPolicy"] as? String, "positive-displayed-count-in-visible-samples")
        XCTAssertNil(object["keepEmptyRows"])
        XCTAssertEqual((object["filter"] as? [String: Any])?["globalMinimumPercent"] as? Double, 2)
        XCTAssertEqual((object["authority"] as? [String: Any])?["locusDisplayOrder"] as? [String], ["MHC-B", "MHC-A"])
    }

    func testPercentFilterRequiresOccurrencesOnlyForUnprojectedPositiveCatalogReferenceRows() throws {
        let catalog = GenotypeReviewableRowCatalog(schemaID: GenotypeReviewableRowCatalog.schemaID, schemaVersion: 1,
            samples: ["S1"], rows: [.init(kind: .reference, callID: "reference:MHC-A:allele", displayName: "allele", locus: "MHC-A",
                stableID: nil, section: "reference", sortKey: "A", supportBySample: ["S1": 7])])
        let result = GenotypeTestFixtures.makeResult(calls: [], reviewableRowCatalog: catalog)
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        XCTAssertThrowsError(try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar, allProjection: nil,
            filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil), filter: .init(matrixMinimumPercent: 10)))
        let captured = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [
            .init(label: "allele", locus: "MHC-A", cells: ["7"])])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar, allProjection: nil,
            filteredProjection: captured, generatedAt: timestamp, authority: .init(analysis: nil), filter: .init(matrixMinimumPercent: 10))
        XCTAssertEqual(snapshot.filteredMatrix.rows.first?.cells.first?.displayValue, 7)
        let readFiltered = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar, allProjection: nil,
            filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil), filter: .init(matrixMinimumReads: 5))
        XCTAssertEqual(readFiltered.filteredMatrix.rows.first?.cells.first?.displayValue, 7)
    }

    func testExportRejectsConsistentMatrixCorruptionWithUnchangedScientificWitnesses() async throws {
        let original = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1)]),
            sidecar: .empty(generatedAt: timestamp), allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["allMatrix", "filteredMatrix"] {
            var matrix = try XCTUnwrap(object[key] as? [String: Any])
            var rows = try XCTUnwrap(matrix["rows"] as? [[String: Any]])
            var cells = try XCTUnwrap(rows[0]["cells"] as? [[String: Any]])
            cells[0]["rawSupport"] = 90; cells[0]["displayValue"] = 90
            rows[0]["cells"] = cells; matrix["rows"] = rows; object[key] = matrix
        }
        let corrupted = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(corrupted.sourceRevision, original.sourceRevision)
        XCTAssertEqual(corrupted.capturedScientificInputs, original.capturedScientificInputs)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-corrupt-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("report.xlsx")
        try Data("prior report".utf8).write(to: output)
        do {
            _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: corrupted, outputURL: output,
                provenance: .init(toolVersion: "test", argv: ["test"]))
            XCTFail("incoherent decoded scientific snapshot was published")
        } catch {}
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "prior report")
    }

    func testAbbreviatedViewportLabelExportsWithNativeTargetIdentity() async throws {
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001:01", reads: 8)])
        let viewport = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [
            .init(label: "A*001", rawGenotype: "Mafa-A*001:01", locus: "MHC-A", cells: ["8"])])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: viewport, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertEqual(snapshot.filteredMatrix.rows[0].target.genotype, "Mafa-A*001:01")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lge-abbreviated-\(UUID().uuidString).xlsx")
        _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot, outputURL: output,
            provenance: .init(toolVersion: "test", argv: ["test"]))
        XCTAssertTrue((try inspect(output)["filteredLabels"] as? [String] ?? []).contains("A*001"))
    }

    func testFilteredRowsRequirePositiveDisplayedEvidenceWithinVisibleSamples() throws {
        let calls = [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 1),
            GenotypeTestFixtures.makeCall(sample: "S2", genotype: "Mafa-A*002", reads: 9),
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*003", reads: 7)]
        let catalog = GenotypeReviewableRowCatalog(schemaID: GenotypeReviewableRowCatalog.schemaID, schemaVersion: 1,
            samples: ["S1", "S2"], rows: [
                .init(kind: .reference, callID: "zero", displayName: "Mafa-A*004", locus: "MHC-A", stableID: nil, section: "reference", sortKey: "zero", supportBySample: ["S1": 0, "S2": 0]),
                .init(kind: .reference, callID: "mixed", displayName: "Mafa-A*003", locus: "MHC-A", stableID: nil, section: "reference", sortKey: "mixed", supportBySample: ["S1": 7, "S2": 0])])
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: timestamp)
        sidecar.matrixReviews = [
            .init(target: .cell(locus: "MHC-A", genotype: "Mafa-A*003", sample: "S2"), disposition: .falseNegative, author: "Tester", timestamp: timestamp),
            .init(target: .cell(locus: "MHC-A", genotype: "Mafa-A*004", sample: "S1"), disposition: .falseNegative, author: "Tester", timestamp: timestamp)]
        sidecar.matrixComments = [
            .init(target: .cell(locus: "MHC-A", genotype: "Mafa-A*003", sample: "S2"), body: "retained zero comment", author: "Tester", timestamp: timestamp),
            .init(target: .cell(locus: "MHC-A", genotype: "Mafa-A*004", sample: "S1"), body: "does not keep zero row", author: "Tester", timestamp: timestamp)]
        let result = GenotypeTestFixtures.makeResult(calls: calls, reviewableRowCatalog: catalog)
        let headless = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar, allProjection: nil,
            filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil), filter: .init(matrixMinimumReads: 5))
        XCTAssertEqual(Set(headless.allMatrix.rows.map(\.displayName)), ["Mafa-A*001", "Mafa-A*002", "Mafa-A*003", "Mafa-A*004"])
        XCTAssertEqual(Set(headless.filteredMatrix.rows.map(\.displayName)), ["Mafa-A*002", "Mafa-A*003"])
        let projection = GenotypeViewProjection(lens: "genotype", sampleColumns: ["S1"], rows: [
            .init(label: "Mafa-A*001", locus: calls[0].locusGroup, cells: [""]),
            .init(label: "Mafa-A*002", locus: calls[1].locusGroup, cells: [""]),
            .init(label: "Mafa-A*003", locus: calls[2].locusGroup, cells: ["7"]),
            .init(label: "Mafa-A*004", locus: "MHC-A", cells: ["0"])])
        let projected = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar, allProjection: nil,
            filteredProjection: projection, generatedAt: timestamp, authority: .init(analysis: nil))
        XCTAssertEqual(projected.filteredMatrix.rows.map(\.displayName), ["Mafa-A*003"])
        let retainedMixed = try XCTUnwrap(headless.filteredMatrix.rows.first { $0.displayName == "Mafa-A*003" })
        XCTAssertEqual(retainedMixed.cells.first { $0.sampleID == "S2" }?.review, "false-negative")
        XCTAssertEqual(retainedMixed.cells.first { $0.sampleID == "S2" }?.comment, "retained zero comment")
    }
}
