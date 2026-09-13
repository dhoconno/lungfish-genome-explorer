import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeEditableWorkbookTests: XCTestCase {
    func testCanonicalOpeningRejectsSidecarThatAppearedAfterGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        let annotations = fixture.root.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let data = try Data(contentsOf: annotations)
        try FileManager.default.removeItem(at: annotations)
        try fixture.service.attestGeneratedWorkbook(workbookURL: fixture.workbook, bundleURL: fixture.root)
        try data.write(to: annotations)
        XCTAssertThrowsError(try GenotypeEditableWorkbookService.canonicalEditableWorkbookURL(in: fixture.root))
    }

    func testEvidencePreservationRejectsEscapingDirectorySymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("artifacts/workbook-edits"), withDestinationURL: outside)
        let inspection = try fixture.service.inspect(bundleURL: fixture.root)
        XCTAssertThrowsError(try fixture.service.preserveEvidence(inspection))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testAttestationRejectsIncompleteEditableSchema() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit("w['Edit Calls'].delete_cols(2)")
        XCTAssertThrowsError(try fixture.service.attestGeneratedWorkbook(workbookURL: fixture.workbook, bundleURL: fixture.root))
    }

    func testLegacyManualCallsAreReadOnlyAndRejectBypassedProtection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed(callEditingSupported: false)
        try fixture.run("from openpyxl import load_workbook; w=load_workbook(p); assert w['Edit Calls']['G2'].protection.locked; assert 'legacy' in str(w['Editing Guide']['B2'].value).lower()")
        try fixture.edit("w['Edit Calls']['G2']='set'; w['Edit Calls']['H2']='M2'")
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }
    func testExplicitH2ClearAndCommentSetClear() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit("w['Edit Calls']['G3']='clear'; w['Edit Matrix']['H2']='set'; w['Edit Matrix']['I2']='checked'")
        let changes = try fixture.service.inspect(bundleURL: fixture.root).changes
        XCTAssertEqual(changes.count, 2)
        XCTAssertNil(changes.first(where: { $0.kind == .call })?.value)
        XCTAssertEqual(changes.first(where: { $0.kind == .call })?.slot, .h2)
        XCTAssertEqual(changes.first(where: { $0.kind == .comment })?.value, "checked")
        try fixture.edit("w['Edit Matrix']['H2']='clear'; w['Edit Matrix']['I2']=None")
        XCTAssertNil(try fixture.service.inspect(bundleURL: fixture.root).changes.first(where: { $0.kind == .comment })?.value)
    }

    func testFalsePositiveFalseNegativeAndClearUseAttestedSupport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed(catalog: "{'samples':['S1','S2'],'rows':[{'locus':'A','display_name':'G1','support_by_sample':[{'sample':'S1','support':12},{'sample':'S2','support':0}]}]}")
        try fixture.edit("\nfor row in w['Edit Matrix'].iter_rows(min_row=2):\n if '\"kind\": \"cell\"' in str(row[1].value):\n  row[5].value='set'; row[6].value='false-positive' if row[2].value else 'false-negative'\n")
        let changes = try fixture.service.inspect(bundleURL: fixture.root).changes
        XCTAssertEqual(Set(changes.compactMap(\.value)), ["false-positive", "false-negative"])
        try fixture.edit("\nfor row in w['Edit Matrix'].iter_rows(min_row=2):\n if '\"kind\": \"cell\"' in str(row[1].value):\n  row[5].value='clear'; row[6].value=None\n")
        XCTAssertEqual(try fixture.service.inspect(bundleURL: fixture.root).changes.count, 2)
    }

    func testStaleManifestAndValuesWithoutExplicitOperationAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit("w['Edit Calls']['H2']='M2'")
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
        try fixture.seed()
        try Data("{\"changed\":true}".utf8).write(to: fixture.root.appendingPathComponent(ONTGenotypeResultBundleManifest.filename))
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }

    func testRoundTripAndExplicitOperationsWithReorderedColumns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        XCTAssertTrue(try fixture.service.inspect(bundleURL: fixture.root).changes.isEmpty)
        try fixture.edit("ws=w['Edit Calls']; ws['G2']='set'; ws['H2']='M2'; rows=list(ws.values); w.remove(ws); ws=w.create_sheet('Edit Calls'); [ws.append(list(reversed(r))) for r in rows]")
        let inspection = try fixture.service.inspect(bundleURL: fixture.root)
        XCTAssertEqual(inspection.changes.count, 1)
        XCTAssertEqual(inspection.changes.first?.value, "M2")
    }

    func testRejectsRawEvidenceTamperingAndStaleSidecar() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit("w['Reads']['B2']=999")
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
        try fixture.seed()
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("annotations.json"))
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }

    func testRejectsUnknownDuplicateAndMissingIDsWithoutMutatingAnnotations() throws {
        for edit in ["ws['A2']='unknown'", "ws.append([c.value for c in ws[2]])", "ws.delete_rows(2)"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.seed()
            let before = try Data(contentsOf: fixture.root.appendingPathComponent("annotations.json"))
            try fixture.edit("ws=w['Edit Calls']; " + edit)
            XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("annotations.json")), before)
        }
    }

    private struct Fixture {
        let root: URL
        let python: URL
        let service: GenotypeEditableWorkbookService
        var workbook: URL { root.appendingPathComponent("current.xlsx") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
            service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
            try Data("{}".utf8).write(to: root.appendingPathComponent(ONTGenotypeResultBundleManifest.filename))
            try GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-11T00:00:00Z").encoded().write(to: root.appendingPathComponent("annotations.json"))
        }
        func seed(catalog: String = "{}", callEditingSupported: Bool = true) throws {
            try run("from openpyxl import Workbook; w=Workbook(); w.active.title='Reads'; w.active.append(['Sample','Reads']); w.active.append(['S1',12])\n" + GenotypeEditableWorkbookService.seedScript + "\nseed_editable_tables(w, [{'sample':'S1','locus':'A','haplotype1':'M1','haplotype2':'M1','baselineHaplotype1':'M1','baselineHaplotype2':'M1'}], {}, " + catalog + ", " + (callEditingSupported ? "True" : "False") + "); w.save(p)")
            try service.attestGeneratedWorkbook(workbookURL: workbook, bundleURL: root, callEditingSupported: callEditingSupported)
        }
        func edit(_ code: String) throws { try run("from openpyxl import load_workbook; w=load_workbook(p); " + code + "\nw.save(p)") }
        func run(_ code: String) throws {
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", "import sys; p=sys.argv[1]; " + code, workbook.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
