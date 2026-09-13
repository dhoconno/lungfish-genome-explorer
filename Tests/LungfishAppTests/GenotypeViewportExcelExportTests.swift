import LungfishKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

final class GenotypeViewportExcelExportTests: XCTestCase {
    /// Opt-in integration against a caller-owned disposable bundle. The test
    /// clones even that input before invoking recovery-capable production APIs.
    @MainActor
    func testDisposableRealBundleControllerAndProductionExcelParity() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_EXCEL_QA_BUNDLE"] else {
            throw XCTSkip("Set LUNGFISH_EXCEL_QA_BUNDLE to a disposable genotype bundle")
        }
        let python = try XCTUnwrap(managedOpenpyxlPythonURL())
        let root = try temporaryDirectory()
        // Retain private artifacts outside the repository for independent QA.
        print("Excel QA retained artifacts: \(root.path)")
        let input = URL(fileURLWithPath: path)
        let projectInput = ProcessInfo.processInfo.environment["LUNGFISH_EXCEL_QA_PROJECT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        let witnessedInput = projectInput ?? input
        let before = try bundleWitness(witnessedInput)
        defer { XCTAssertEqual(try? bundleWitness(witnessedInput), before) }
        let bundle: URL
        if let projectInput {
            let prefix = projectInput.path + "/"
            XCTAssertTrue(input.standardizedFileURL.path.hasPrefix(prefix))
            let projectCopy = root.appendingPathComponent("working.lungfish")
            try FileManager.default.copyItem(at: projectInput, to: projectCopy)
            bundle = projectCopy.appendingPathComponent(String(input.standardizedFileURL.path.dropFirst(prefix.count)))
        } else {
            bundle = root.appendingPathComponent("working.lungfishgenotype")
            try FileManager.default.copyItem(at: input, to: bundle)
        }
        let result = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let source = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("source-current.xlsx"))
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        XCTAssertEqual(snapshot.filters["matrixMinimumReads"], "5")
        XCTAssertFalse(snapshot.rows.isEmpty)
        XCTAssertFalse(snapshot.haplotypeCalls?.isEmpty ?? true)
        if projectInput != nil {
            let definitionPath = try XCTUnwrap(snapshot.filters["activeHaplotypeDefinitionPath"])
            XCTAssertTrue(definitionPath.hasPrefix(root.path + "/"))
            XCTAssertTrue(snapshot.provenanceInputURLs.contains(URL(fileURLWithPath: definitionPath)))
        }
        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        let output = root.appendingPathComponent("filtered.xlsx")
        _ = try GenotypeViewportExportService().export(snapshot: snapshot, format: .pivotExcel, to: output)
        let projectionURL = output.appendingPathExtension("view-projection.json")
        XCTAssertEqual(try JSONDecoder().decode(GenotypeViewProjection.self, from: Data(contentsOf: projectionURL)), projection)
        let currentCalls = controller.testingCurrentWorkbookHaplotypeCalls()
        let annotationURL = output.appendingPathExtension("annotations.json")
        let manifest = try GenotypeWorkbookRevisionService(pythonExecutableURL: python).applyHaplotypeOverrides(
            currentCalls, annotationSidecarURL: annotationURL, into: bundle
        )
        let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        try FileManager.default.copyItem(at: current, to: root.appendingPathComponent("generated-current.xlsx"))
        let expectedCalls = root.appendingPathComponent("expected-current-calls.json")
        try JSONEncoder().encode(currentCalls).write(to: expectedCalls)
        let report = try runPython(python, script: Self.realBundleParityScript, arguments: [
            output.path, projectionURL.path, current.path, expectedCalls.path,
            root.appendingPathComponent("workbook-dump.json").path,
        ])
        print(report)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertTrue(provenance.argv.containsSubsequence(["--min-reads", "5"]))
        XCTAssertEqual(provenance.options.resolvedDefaults["minReads"], .integer(5))
        let records = provenance.files + provenance.steps.flatMap(\.inputs) + provenance.steps.flatMap(\.outputs)
        for url in [output, projectionURL, annotationURL] {
            let record = try XCTUnwrap(records.first { $0.path == url.path })
            XCTAssertNotNil(record.checksumSHA256)
            XCTAssertNotNil(record.fileSize)
        }
        let latest = try XCTUnwrap(manifest.workbookRevisions?.last)
        XCTAssertEqual(latest.sha256, try ProvenanceFileHasher.sha256(of: current))
        let currentProvenance = bundle.appendingPathComponent(try XCTUnwrap(latest.provenancePath))
        try FileManager.default.copyItem(at: currentProvenance, to: root.appendingPathComponent("current-provenance.json"))
        try exerciseDisposableCohortEdits(controller: controller, result: result, bundle: bundle, root: root, python: python)
        XCTAssertEqual(try bundleWitness(witnessedInput), before)
    }

    @MainActor
    private func exerciseDisposableCohortEdits(controller: GenotypeResultViewController, result: ONTGenotypeResultBundleData, bundle: URL, root: URL, python: URL) throws {
        let current = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        _ = try runPython(python, script: #"""
import sys,json
from openpyxl import load_workbook
w=load_workbook(sys.argv[1]); s=w['Edit Matrix']; h={c.value:c.column for c in s[1]}
done=set()
for cells in s.iter_rows(min_row=2):
    def value(key): return cells[h[key]-1].value
    def put(key,value): cells[h[key]-1].value=value
    t=json.loads(value('Target'))
    if t['kind']=='row' and 'row' not in done:
        put('Comment operation','set'); put('Comment value','QA row comment'); done.add('row')
    if t['kind']!='cell' or value('Current review'): continue
    reads=value('Reads')
    if isinstance(reads,(int,float)) and reads>5 and 'fp' not in done:
        put('Review operation','set'); put('Review value','false-positive')
        put('Comment operation','set'); put('Comment value','QA cell comment'); done.add('fp')
    elif reads==0 and 'fn' not in done:
        put('Review operation','set'); put('Review value','false-negative'); done.add('fn')
assert done=={'row','fp','fn'},done
w.save(sys.argv[1])
"""#, arguments: [current.path])
        let service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
        let inspection = try service.inspect(bundleURL: bundle)
        XCTAssertEqual(inspection.changes.count, 4)
        let original = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        try controller.acceptEditableWorkbook(inspection, using: service)
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(try XCTUnwrap(requests.first).snapshot.annotationOnly)
        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundle)
        XCTAssertEqual(saved.matrixReviews.count, original.matrixReviews.count + 2)
        XCTAssertTrue(original.matrixReviews.allSatisfy { saved.matrixReviews.contains($0) })
        XCTAssertTrue(saved.matrixComments.contains { $0.body == "QA row comment" })
        XCTAssertTrue(saved.matrixComments.contains { $0.body == "QA cell comment" })
        let annotationURL = bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let importProvenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: importProvenanceURL)) as? [String: Any])
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        let explicit = try XCTUnwrap(options["explicit"] as? [String: Any])
        let accepted = try XCTUnwrap(explicit["acceptedEditableWorkbook"] as? [String: Any])
        XCTAssertEqual(accepted["workbookSHA256"] as? String, inspection.workbookSHA256)
        let evidence = URL(fileURLWithPath: try XCTUnwrap(accepted["evidenceDirectory"] as? String))
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: evidence.appendingPathComponent("input.xlsx")), inspection.workbookSHA256)
        try FileManager.default.copyItem(at: importProvenanceURL, to: root.appendingPathComponent("accepted-edit-provenance.json"))
        let immediateCalls = controller.testingCurrentWorkbookHaplotypeCalls()
        let revised = try GenotypeWorkbookRevisionService(pythonExecutableURL: python).applyHaplotypeOverrides(immediateCalls, annotationSidecarURL: annotationURL, into: bundle)
        let refreshed = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        try FileManager.default.copyItem(at: refreshed, to: root.appendingPathComponent("refreshed-current.xlsx"))
        let reopened = GenotypeResultViewController()
        _ = reopened.view
        reopened.configure(result: try ONTGenotypeResultBundle.loadResult(from: bundle))
        reopened.testingApplyDisplayState(.init(summaryViewMode: .matrix, matrixMinimumReads: 5))
        XCTAssertEqual(reopened.testingCurrentWorkbookHaplotypeCalls(), immediateCalls)
        let finalSnapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        let finalProjection = GenotypeViewProjectionSerializer.makeProjection(from: finalSnapshot)
        XCTAssertEqual(GenotypeViewProjectionSerializer.makeProjection(from: try XCTUnwrap(reopened.testingCurrentExportSnapshot())).haplotypeCalls, finalProjection.haplotypeCalls)
        let finalOutput = root.appendingPathComponent("filtered-final.xlsx")
        _ = try GenotypeViewportExportService().export(snapshot: finalSnapshot, format: .pivotExcel, to: finalOutput)
        let callsURL = root.appendingPathComponent("expected-final-calls.json")
        try JSONEncoder().encode(immediateCalls).write(to: callsURL)
        print(try runPython(python, script: Self.realBundleParityScript, arguments: [finalOutput.path, finalOutput.appendingPathExtension("view-projection.json").path, refreshed.path, callsURL.path, root.appendingPathComponent("final-workbook-dump.json").path]))
        let latest = try XCTUnwrap(revised.workbookRevisions?.last)
        XCTAssertEqual(latest.sha256, try ProvenanceFileHasher.sha256(of: refreshed))
        try FileManager.default.copyItem(at: bundle.appendingPathComponent(try XCTUnwrap(latest.provenancePath)), to: root.appendingPathComponent("refreshed-current-provenance.json"))
        XCTAssertEqual(result.calls, try ONTGenotypeResultBundle.loadResult(from: bundle).calls)
    }

    private func bundleWitness(_ root: URL) throws -> [String: String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var witness: [String: String] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                witness[String(url.path.dropFirst(root.path.count))] = try ProvenanceFileHasher.sha256(of: url)
            }
        }
        return witness
    }

    private static let realBundleParityScript = #"""
import json, sys
from openpyxl import load_workbook
filtered, projection_path, current_path, calls_path, dump_path = sys.argv[1:]
projection = json.load(open(projection_path))
sidecar = json.load(open(filtered + '.annotations.json'))
reviews = {(r['target'].get('locus'),r['target'].get('genotype'),r['target'].get('sample'),r['target'].get('stableClusterID')): r['disposition'] for r in sidecar.get('matrixReviews', [])}
wb = load_workbook(filtered, data_only=False)
assert wb.sheetnames == ["Genotype Matrix", "Haplotype Calls", "Export Metadata"], wb.sheetnames
matrix = wb["Genotype Matrix"]
samples = projection["sampleColumns"]
assert [c.value for c in matrix[1]] == ["Genotype", "Locus", "Stable Cluster ID"] + samples + ["Raw Genotype"]
assert matrix.max_row == len(projection["rows"]) + 1
assert matrix.max_column == len(samples) + 4
columns = {c.value: c.column - 1 for c in matrix[1]}
def text(value):
    return "" if value is None else str(value)
def cells(sheet):
    return [[text(c.value) for c in row] for row in sheet]
checked = 0
for index, expected in enumerate(projection["rows"], 2):
    row = matrix[index]
    assert [text(c.value) for c in row[:3]] == [expected["label"], expected.get("locus", ""), expected.get("stableClusterID", "")], index
    assert text(row[columns['Raw Genotype']].value) == expected.get('rawGenotype', expected['label'])
    sample_cells = [row[columns[sample]] for sample in samples]
    expected_cells = []
    for sample, value in zip(samples, expected['cells']):
        review = reviews.get((expected.get('locus'),expected.get('rawGenotype',expected['label']),sample,expected.get('stableClusterID')))
        expected_cells.append('FN' if review=='falseNegative' else '['+value+']' if review=='falsePositive' and value else value)
    assert [text(c.value) for c in sample_cells] == expected_cells, index
    for offset, c in enumerate(sample_cells):
        colors = expected.get("cellColorsHex") or []
        color = colors[offset] if offset < len(colors) else None
        color = color or expected.get("rowColorHex")
        if color:
            assert c.fill.fgColor.type == "rgb" and c.fill.fgColor.rgb[-6:].upper() == color.lstrip("#").upper(), (index, offset, c.fill.fgColor, color)
        checked += 1
keys = ["sample", "locus", "haplotype1", "haplotype2", "haplotype1Status", "haplotype2Status", "haplotype1Source", "haplotype2Source", "baselineHaplotype1", "baselineHaplotype2", "comment"]
assert cells(wb["Haplotype Calls"])[1:] == [[text(call.get(key)) for key in keys] for call in projection["haplotypeCalls"]]
metadata = {r[0]: r[1] for r in cells(wb["Export Metadata"])[1:]}
for key, value in projection["filterContext"].items():
    assert metadata[key] == value, key
for key, value in projection["sourceRevision"].items():
    assert metadata["Source " + key] == text(value), key
current = load_workbook(current_path, data_only=False)
source = load_workbook(__import__('os').path.join(__import__('os').path.dirname(filtered), 'source-current.xlsx'), data_only=False)
expected = json.load(open(calls_path))
actual = cells(current["Haplotype Calls"])
headers = actual[0]
index = {name: i for i, name in enumerate(headers)}
want = {(c["sample"], c["locus"]): (c["haplotype1"], c["haplotype2"]) for c in expected}
got = {(r[0], r[1]): (r[2], r[3]) for r in actual[1:]}
assert got == want, (got, want)
evidence_cells = 0
original_review_values = {}
if '_LGE Matrix Review State' in current.sheetnames:
    for row in current['_LGE Matrix Review State'].iter_rows(min_row=2,values_only=True):
        original_review_values[(row[0],row[6])] = json.loads(row[8])['value']
for source_sheet in source:
    if not source_sheet.title.startswith("Full Sequencing Results"):
        continue
    current_sheet = current[source_sheet.title]
    old = cells(source_sheet)
    new = cells(current_sheet)
    first = next(i for i, row in enumerate(old) if row[0].endswith(" alleles"))
    new_by_label = {row[0]: row for row in new}
    new_cells_by_label = {text(row[0].value): row for row in current_sheet}
    for row in old[first:]:
        if not row[0] or row[0].endswith(" alleles"):
            continue
        actual_raw = [text(original_review_values.get((current_sheet.title,cell.coordinate),cell.value)) for cell in new_cells_by_label[row[0]][3:]]
        assert actual_raw == row[3:], row[0]
        evidence_cells += len(row[3:])
def dump(book):
    return {sheet.title: {"values": cells(sheet), "annotations": [
        {"cell": cell.coordinate, "comment": cell.comment.text if cell.comment else None,
         "fill": str(cell.fill.fgColor), "bold": cell.font.bold, "italic": cell.font.italic,
         "font": str(cell.font.color), "border": str(cell.border)}
        for row in sheet for cell in row
    ]} for sheet in book}
json.dump({"filtered": dump(wb), "current": dump(current)}, open(dump_path, "w"), indent=2)
print(json.dumps({"matrixRows": len(projection["rows"]), "samples": len(samples), "checkedCells": checked, "unfilteredEvidenceCells": evidence_cells, "filteredCalls": len(projection["haplotypeCalls"]), "currentCalls": len(want), "currentHeaders": headers}), flush=True)
sidecar = json.load(open(filtered + '.annotations.json'))
if sidecar.get('matrixReviews'):
    annotations = cells(current['Matrix Annotations'])
    validation = annotations[0].index('Validation Status')
    assert all(row[validation] != 'invalid' for row in annotations[1:]), 'Current workbook could not map captured matrix annotations to exact evidence identities'
edits = cells(current['Edit Matrix'])
targets = [json.loads(row[1]) for row in edits[1:]]
assert any(t['kind']=='row' for t in targets) and any(t['kind']=='cell' for t in targets)
"""#

    @MainActor
    func testReviewedActiveAnalysisReachesProductionFilteredWorkbookAndProvenance()
        async throws
    {
        let python = try XCTUnwrap(managedOpenpyxlPythonURL())
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

        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        let projectedCall = try XCTUnwrap(snapshot.haplotypeCalls?.first)
        XCTAssertEqual(projectedCall.haplotype1, "M1A")
        XCTAssertEqual(projectedCall.haplotype2, "M1A")
        XCTAssertEqual(projectedCall.baselineHaplotype1, "M1A")
        XCTAssertEqual(projectedCall.baselineHaplotype2, "-")
        XCTAssertEqual(snapshot.rows.map(\.genotype), [retained.genotype])

        let sourceURL = bundleURL.appendingPathComponent("source.xlsx")
        _ = try runPython(
            python,
            script: Self.makeScientificSourceWorkbookScript,
            arguments: [sourceURL.path]
        )
        let projectionURL = root.appendingPathComponent("captured-projection.json")
        try JSONEncoder().encode(
            GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        ).write(to: projectionURL)
        let annotationURL = root.appendingPathComponent("captured-annotations.json")
        let annotationData = try XCTUnwrap(snapshot.annotationSidecarData)
        try annotationData.write(to: annotationURL)
        let sidecar = try GenotypeAnnotationSidecar.decode(annotationData)
        let outputURL = root.appendingPathComponent("filtered.xlsx")
        let buildURL = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(
            at: buildURL,
            withIntermediateDirectories: true
        )
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", bundleURL.path,
            "--output", outputURL.path,
            "--view-projection", projectionURL.path,
            "--annotations", annotationURL.path,
            "--min-percent", "7.5",
            "--percent-basis", "sample-retained",
        ])
        try await command.exportFilteredCopy(
            of: sourceURL,
            result: result,
            sidecar: sidecar,
            thresholds: .init(
                minimumPercent: 7.5,
                percentBasis: .sampleRetained
            ),
            projection: GenotypeViewProjectionSerializer.makeProjection(
                from: snapshot
            ),
            projectionURL: projectionURL,
            annotationURL: annotationURL,
            capturedInputRecords: [
                ProvenanceRecorder.fileRecord(
                    url: projectionURL,
                    role: .input
                ),
                ProvenanceRecorder.fileRecord(
                    url: annotationURL,
                    role: .input
                ),
            ],
            bundleURL: bundleURL,
            outputURL: outputURL,
            buildDir: buildURL,
            managedPythonResolver: { python },
            startedAt: Date()
        )

        let dumped = try runPython(
            python,
            script: Self.dumpScientificFilteredWorkbookScript,
            arguments: [outputURL.path]
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(dumped.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            payload["sheets"] as? [String],
            ["Genotype Matrix", "Haplotype Calls", "Export Metadata"]
        )
        XCTAssertEqual(
            payload["call"] as? [String],
            [
                "AnimalA", "MHC-A", "M1A", "M1A", "called", "called",
                "pipeline", "pipeline", "M1A", "-",
            ]
        )
        XCTAssertEqual(
            payload["matrixRows"] as? [[String]],
            [[retained.genotype, "MHC-A", "", "100"]]
        )
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: String])
        XCTAssertEqual(metadata["minimumSupportPercent"], "7.5")
        XCTAssertEqual(metadata["supportDenominator"], "Sample Retained")
        XCTAssertEqual(metadata["matrixMinimumPercent"], "0.0")
        XCTAssertEqual(metadata["matrixPercentDenominator"], "Viewed Locus")
        XCTAssertEqual(metadata["Source analysisRevisionID"], "")
        XCTAssertEqual(metadata["Source definitionSetID"], definition.id)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
        ))
        XCTAssertTrue(provenance.argv.containsSubsequence([
            "--min-percent", "7.5", "--percent-basis", "sample-retained",
        ]))
        XCTAssertEqual(
            provenance.options.resolvedDefaults["minPercent"],
            .number(7.5)
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["percentBasis"],
            .string("sample-retained")
        )
        let inputs = provenance.files + provenance.steps.flatMap(\.inputs)
        XCTAssertTrue(inputs.contains {
            $0.path == projectionURL.path && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(inputs.contains {
            $0.path == annotationURL.path && $0.checksumSHA256 != nil
        })
        let definitionURL = inputsURL.appendingPathComponent(
            "haplotype-definition.json"
        )
        XCTAssertTrue(inputs.contains {
            $0.path == definitionURL.path && $0.checksumSHA256 != nil
        })
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
            format: .excel,
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
                format: .excel,
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
                format: .excel,
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
        XCTAssertTrue(delimited.contains("Locus,Row,AnimalA,AnimalB"))
        XCTAssertTrue(delimited.contains("AnimalA"))
        XCTAssertTrue(delimited.contains("AnimalB"))
        XCTAssertTrue(delimited.contains("MHC-A,01_M1_A_01"))
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

    private static let makeScientificSourceWorkbookScript = #"""
import sys
from openpyxl import Workbook

wb = Workbook()
ws = wb.active
ws.title = "Synthetic"
ws.append(["Animal ID", None, None, "AnimalA"])
ws.append(["GS ID", "Total", "Average", "AnimalA"])
ws.append(["Mapped Read Count", 103, 103, 103])
for locus in ["MHC-A"]:
    for slot in (1, 2):
        ws.append([f"{locus} Haplotype {slot}", None, None, "stale"])
ws.append(["Comments", "Subtotal", "# Obs.", None])
ws.append(["Genotype", "Total", "# Obs.", "AnimalA"])
ws.append(["MHC-A alleles", None, None, None])
ws.append(["01_M1_A_marker", 100, 1, 100])
ws.append(["02_M2_A_marker", 3, 1, 3])
wb.save(sys.argv[1])
"""#

    private static let dumpScientificFilteredWorkbookScript = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
calls = wb["Haplotype Calls"]
matrix = wb["Genotype Matrix"]
metadata = wb["Export Metadata"]
out = {
    "sheets": wb.sheetnames,
    "call": [str(calls.cell(2, column).value or "") for column in range(1, 11)],
    "matrixRows": [
        [str(matrix.cell(row, column).value or "") for column in range(1, 5)]
        for row in range(2, matrix.max_row + 1)
    ],
    "metadata": {
        str(metadata.cell(row, 1).value or ""): str(metadata.cell(row, 2).value or "")
        for row in range(2, metadata.max_row + 1)
    },
}
print(json.dumps(out, sort_keys=True))
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
