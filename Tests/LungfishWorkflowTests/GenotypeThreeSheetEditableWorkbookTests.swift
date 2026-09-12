import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeThreeSheetEditableWorkbookTests: XCTestCase {
    func testDirectCallResetAndFalsePositiveNoteProduceExistingChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit(#"w['Haplotype Calls']['D2']='M2A'; w['Haplotype Calls']['J2']='Use pipeline call'; c=w['Genotype Matrix']['D5']; c.comment=Comment(c.comment.text+'\n[LGE Edit v2]\nReview operation: set\nReview value: \"false-positive\"\nComment operation: keep\nComment value: \"\"\n[/LGE Edit v2]','LGE')"#)

        let inspection = try fixture.service.inspect(bundleURL: fixture.root)
        XCTAssertEqual(inspection.changes.first(where: { $0.kind == .call && $0.slot == .h1 })?.value, "M2A")
        let h2Reset = try XCTUnwrap(inspection.changes.first(where: { $0.kind == .call && $0.slot == .h2 }))
        XCTAssertNil(h2Reset.value)
        XCTAssertEqual(inspection.changes.first(where: { $0.kind == .review })?.value, "false-positive")
        XCTAssertEqual(inspection.changes.first(where: { $0.kind == .review })?.sample, "scientific-S1")
        XCTAssertEqual(inspection.changes.first(where: { $0.kind == .review })?.target?.stableClusterID, "cluster-1")
    }

    func testRejectsScientificValuesFormulasMetadataLinksAndPhysicalReordering() throws {
        let edits = [
            "w['Genotype Matrix']['D5']=99",
            "w['Genotype Matrix']['D2']='=1+1'",
            "w['Export Metadata']['B1']='forged-role'",
            "w['Genotype Matrix']['D5'].hyperlink='https://example.invalid'",
            "ws=w['Haplotype Calls']; ws.move_range('A2:N2',rows=1)"
        ]
        for edit in edits {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.seed(); try fixture.edit(edit)
            XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root), edit)
        }
    }

    func testRejectsValueFormulaAndInternalLinkOnAttestedNullNoteTarget() throws {
        let edits = [
            "w['Genotype Matrix']['D5']=99",
            "w['Genotype Matrix']['D5']='=1+1'",
            "c=w['Genotype Matrix']['D5']; c._hyperlink=Hyperlink(ref='D5',location=\"'Genotype Matrix'!D1\")"
        ]
        for edit in edits {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.seed(displayValue: nil); try fixture.edit(edit)
            XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root), edit)
        }
        let deletedNote = try Fixture(); defer { deletedNote.remove() }
        try deletedNote.seed(displayValue: nil)
        try deletedNote.edit("w['Genotype Matrix']['D5'].comment=None")
        XCTAssertTrue(try deletedNote.service.inspect(bundleURL: deletedNote.root).changes.isEmpty)
    }

    func testRejectsInternalHyperlinkOnEditableCallTarget() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit("c=w['Haplotype Calls']['D2']; c._hyperlink=Hyperlink(ref='D2',location=\"'Genotype Matrix'!D5\")")
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }

    func testRejectsMissingDuplicateAndUnknownTargetsAndStaleSources() throws {
        let edits = [
            "w['Haplotype Calls'].delete_rows(2)",
            "w['Haplotype Calls'].append([c.value for c in w['Haplotype Calls'][2]])",
            "w['Haplotype Calls']['A2']='workbook-marker-cannot-authorize'"
        ]
        for edit in edits {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.seed(); try fixture.edit(edit)
            XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root), edit)
        }
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed()
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent(ONTGenotypeResultBundleManifest.filename))
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }

    func testBlankedCallRejectsWhileUnchangedAndDeletedNotesAreNoOps() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed()
        XCTAssertTrue(try fixture.service.inspect(bundleURL: fixture.root).changes.isEmpty)
        try fixture.edit("w['Genotype Matrix']['D5'].comment=None")
        XCTAssertTrue(try fixture.service.inspect(bundleURL: fixture.root).changes.isEmpty)
        try fixture.edit("w['Haplotype Calls']['D2']=None")
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
        let annotated = try Fixture(); defer { annotated.remove() }
        try annotated.seed(currentComment: "prior")
        try annotated.edit("w['Genotype Matrix']['D5'].comment=None")
        XCTAssertTrue(try annotated.service.inspect(bundleURL: annotated.root).changes.isEmpty)
    }

    func testNotesSupportMultilineCommentsExplicitClearAndRejectGeneratedTextEdits() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit(#"c=w['Genotype Matrix']['D5']; c.comment=Comment(c.comment.text+'\n[LGE Edit v2]\nReview operation: keep\nReview value: \"\"\nComment operation: set\nComment value: \"line 1\\nline 2\"\n[/LGE Edit v2]','LGE')"#)
        XCTAssertEqual(try fixture.service.inspect(bundleURL: fixture.root).changes.first?.value, "line 1\nline 2")
        try fixture.seed()
        try fixture.edit(#"c=w['Genotype Matrix']['D5']; c.comment=Comment(c.comment.text.replace('Evidence:','Forged:'),'LGE')"#)
        XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root))
    }

    func testNoteJSONValueMayContainLiteralBlockDelimiterText() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed()
        try fixture.edit(#"c=w['Genotype Matrix']['D5']; c.comment=Comment(c.comment.text+'\n[LGE Edit v2]\nReview operation: keep\nReview value: \"\"\nComment operation: set\nComment value: \"before [LGE Edit v2] and [/LGE Edit v2] after\"\n[/LGE Edit v2]','LGE')"#)
        XCTAssertEqual(try fixture.service.inspect(bundleURL: fixture.root).changes.first?.value, "before [LGE Edit v2] and [/LGE Edit v2] after")
    }

    func testRejectsFalseNegativeWithUnknownSupportAndReviewsOnSampleOrRow() throws {
        for address in ["D5", "D1", "C5"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.seed(rawSupport: address == "D5" ? nil : 5)
            try fixture.edit("c=w['Genotype Matrix']['\(address)']; base=c.comment.text if c.comment else ''; c.comment=Comment(base+'\\n[LGE Edit v2]\\nReview operation: set\\nReview value: \\\"false-negative\\\"\\nComment operation: keep\\nComment value: \\\"\\\"\\n[/LGE Edit v2]','LGE')")
            XCTAssertThrowsError(try fixture.service.inspect(bundleURL: fixture.root), address)
        }
    }

    func testEvidencePreservationAndRepeatedInspectionRetainV2Receipts() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed(); try fixture.edit("w['Haplotype Calls']['D2']='M2A'")
        let inspection = try fixture.service.inspect(bundleURL: fixture.root)
        let directory = try fixture.service.preserveEvidence(inspection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.xlsx").path))
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("provenance.json"))) as! [String: Any]
        XCTAssertEqual((receipt["options"] as? [String: Any])?["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try fixture.service.inspect(bundleURL: fixture.root).changes.count, 1)
    }

    func testUnavailableBaselineRejectsBypassedProtectionAndGenuineBlankIsNoOp() throws {
        let unavailable = try Fixture(); defer { unavailable.remove() }
        try unavailable.seed(h1Effective: "manual", h1Pipeline: nil)
        try unavailable.edit("w['Haplotype Calls']['D2']='forged'")
        XCTAssertThrowsError(try unavailable.service.inspect(bundleURL: unavailable.root))
        let blank = try Fixture(); defer { blank.remove() }
        try blank.seed(h1Effective: "", h1Pipeline: "")
        XCTAssertTrue(try blank.service.inspect(bundleURL: blank.root).changes.isEmpty)
    }

    func testExplicitCommentClearAndFormattingOnlyChanges() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.seed(currentComment: "prior")
        try fixture.edit(#"c=w['Genotype Matrix']['D5']; c.comment=Comment(c.comment.text.replace('Comment operation: keep','Comment operation: clear'),'LGE'); c.fill=PatternFill('solid',fgColor='FF00FF')"#)
        let change = try fixture.service.inspect(bundleURL: fixture.root).changes.first
        XCTAssertEqual(change?.kind, .comment)
        XCTAssertNil(change?.value)
    }

    private struct Fixture {
        let root: URL
        let python: URL
        let service: GenotypeEditableWorkbookService
        var workbook: URL { root.appendingPathComponent("current.xlsx") }
        var manifest: URL { root.appendingPathComponent("layout.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
            service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
            try Data("{}".utf8).write(to: root.appendingPathComponent(ONTGenotypeResultBundleManifest.filename))
            try GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z").encoded().write(to: root.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        }

        func seed(rawSupport: Int? = 5, displayValue: Int? = 5, currentComment: String? = nil, h1Effective: String = "M1A", h1Pipeline: String? = "M1A") throws {
            let payload = GenotypeWorkbookPresentation.Payload(
                schemaVersion: 2, role: "editable-current", sourceRevision: ["run": "r1"],
                samples: [.init(id: "scientific-S1", name: "Display One", comment: nil)], loci: ["MHC-A"],
                rows: [.init(id: "row-1", target: .init(kind: "row", locus: "MHC-A", genotype: "G1", stableClusterID: "cluster-1"), displayName: "G1", comment: nil, fillHex: nil, cells: [.init(sampleID: "scientific-S1", displayValue: displayValue, rawSupport: rawSupport, reviewEligible: true, fillHex: nil, comment: currentComment, review: nil)])],
                calls: [.init(id: "call-1", sampleID: "scientific-S1", locus: "MHC-A", h1: .init(effective: h1Effective, pipeline: h1Pipeline, baselineAvailable: h1Pipeline != nil, status: "ok", source: "pipeline"), h2: .init(effective: "M1B", pipeline: "M1B", baselineAvailable: true, status: "ok", source: "pipeline"), comment: nil)],
                colors: [], metadata: [["Scope", "All evidence"]], callEditingSupported: true)
            let data = try JSONEncoder().encode(payload)
            let payloadURL = root.appendingPathComponent("payload.json")
            try data.write(to: payloadURL)
            try run("import json; exec(" + String(reflecting: GenotypeWorkbookPresentation.pythonScript) + "); payload=json.load(open(sys.argv[2])); manifest=render_three_sheet_workbook(payload,p); json.dump(manifest,open(sys.argv[3],'w'),sort_keys=True)", extra: [payloadURL.path, manifest.path])
            try service.attestGeneratedWorkbook(workbookURL: workbook, bundleURL: root, trustedManifest: try Data(contentsOf: manifest))
        }

        func edit(_ code: String) throws { try run("from openpyxl import load_workbook; from openpyxl.comments import Comment; from openpyxl.styles import PatternFill; from openpyxl.worksheet.hyperlink import Hyperlink; w=load_workbook(p); " + code + "; w.save(p)") }
        func run(_ code: String, extra: [String] = []) throws {
            let process = Process(); process.executableURL = python
            process.arguments = ["-c", "import sys; p=sys.argv[1]; " + code, workbook.path] + extra
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
