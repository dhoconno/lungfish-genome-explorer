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

    func testServicePublishesThreeSheetReportAndDurableReplayWithExactWitnesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-excel-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.json")
        let inputBytes = Data("captured input".utf8)
        try inputBytes.write(to: input)
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "=1+1", genotype: "Mafa-A*001", reads: 1)])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumReads: 5), keepEmptyRows: true)
        let output = root.appendingPathComponent("report.xlsx")
        let exported = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot,
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
        XCTAssertTrue((inspection["strings"] as? [String])?.contains("=1+1") == true)
        let replay = root.appendingPathComponent("replayed.xlsx")
        try runPython(arguments: [exported.replayScriptURL.path, exported.snapshotURL.path, replay.path])
        XCTAssertEqual(try inspect(replay)["sheets"] as? [String], inspection["sheets"] as? [String])
        XCTAssertEqual(try Data(contentsOf: input), inputBytes)
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

    private func runPython(arguments: [String]) throws {
        let process = Process(); process.executableURL = python; process.arguments = arguments
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }

    private func inspect(_ output: URL) throws -> [String: Any] {
        let process = Process(); process.executableURL = python
        process.arguments = ["-c", "import openpyxl,json,sys; w=openpyxl.load_workbook(sys.argv[1]); c=[c for s in w for row in s for c in row]; print(json.dumps(dict(sheets=w.sheetnames,formulas=sum(c.data_type=='f' for c in c),strings=[c.value for c in c if isinstance(c.value,str)],matrixD2={s.title:s['D2'].value for s in w if s.title.startswith('Genotype Matrix')})))", output.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        XCTAssertNil(snapshot.filteredMatrix.rows.first?.cells.first?.displayValue)
        XCTAssertEqual(snapshot.filteredMatrix.rows.first?.cells.first?.rawSupport, 1)
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
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lge-manual-\(UUID().uuidString).xlsx")
        _ = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot, outputURL: output,
            provenance: .init(toolVersion: "test", argv: ["test"]))
        XCTAssertEqual(try inspect(output)["sheets"] as? [String], ["Haplotype Calls", "Genotype Matrix - All", "Genotype Matrix - Filtered", "Export Metadata"])
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
            XCTAssertEqual((try inspect(output)["sheets"] as? [String])?.count, 4)
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
            filter: .init(globalMinimumPercent: 2, globalDenominator: .sampleRetained, matrixMinimumReads: 5), keepEmptyRows: true)
        let context = try XCTUnwrap(snapshot.capturedScientificInputs?["capture-context.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: context) as? [String: Any])
        XCTAssertEqual(object["keepEmptyRows"] as? Bool, true)
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
}
