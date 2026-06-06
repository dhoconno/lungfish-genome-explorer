import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeWorkbookRevisionServiceTests: XCTestCase {
    func testApplyHaplotypeOverridesPatchesCurrentWorkbookAndRecordsSidecarProvenance() throws {
        try XCTSkipIf(!pythonCanImportOpenpyxl(), "openpyxl is required for current workbook override verification")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeMCMWorkbookBundle(in: root, outputName: "mcm")
        let annotationURL = fixture.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-04T00:00:00Z")
            .encoded()
            .write(to: annotationURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 5_000) },
            userProvider: { "tester" }
        ).applyHaplotypeOverrides(
            [
                GenotypeWorkbookHaplotypeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotype1: "M3DP",
                    haplotype2: "M7DP",
                    status: "called",
                    notes: "Manual override"
                )
            ],
            annotationSidecarURL: annotationURL,
            into: fixture.bundleURL
        )

        let inspection = try inspectMCMWorkbook(try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))
        XCTAssertEqual(inspection["abbreviatedDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["abbreviatedDPHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["fullDPAHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["fullDPBHaplotype2"], "M7DP")
        XCTAssertEqual(inspection["customDPHaplotype1"], "M3DP")
        XCTAssertEqual(inspection["guideWorkbookUpdateSource"], "Lungfish.app Review viewport")
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .externalEditSnapshot } == true)
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        let provenancePath = try XCTUnwrap(imported.provenancePath)
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: fixture.bundleURL)
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("annotations.json"))
        XCTAssertTrue(provenance.contains("apply-haplotype-overrides"))
    }

    func testImportRevisedWorkbookKeepsPrimaryAndSnapshotsPreviousCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let importedURL = root.appendingPathComponent("collaborator.xlsx")
        try workbookData("collaborator edit").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 1_800) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Collaborator edit")

        let primaryWorkbookURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)
        let currentWorkbookURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        XCTAssertEqual(try Data(contentsOf: primaryWorkbookURL), workbookData("primary"))
        XCTAssertEqual(try Data(contentsOf: currentWorkbookURL), workbookData("collaborator edit"))
        XCTAssertEqual(updatedManifest.primaryWorkbookPath, fixture.manifest.primaryWorkbookPath)
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")

        let snapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: snapshot.path, in: fixture.bundleURL)),
            workbookData("current")
        )
        let imported = try XCTUnwrap(updatedManifest.workbookRevisions?.last)
        XCTAssertEqual(imported.role, .imported)
        XCTAssertEqual(imported.path, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(imported.sourceFilename, importedURL.lastPathComponent)
        XCTAssertNotNil(imported.provenancePath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ONTGenotypeResultBundle.resolvedURL(
                for: try XCTUnwrap(imported.provenancePath),
                in: fixture.bundleURL
            ).path
        ))
    }

    func testImportMigratesOldPrimaryOnlyBundleBeforeReplacingCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "legacy", includeCurrent: false)
        let importedURL = root.appendingPathComponent("reviewed.xlsx")
        try workbookData("reviewed").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 2_400) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Reviewed")

        XCTAssertEqual(updatedManifest.primaryWorkbookPath, "legacy.xlsx")
        XCTAssertEqual(updatedManifest.currentWorkbookPath, "artifacts/workbooks/current.xlsx")
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.primaryWorkbookURL(for: fixture.bundleURL)),
            workbookData("primary")
        )
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            workbookData("reviewed")
        )
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .initialCurrentCopy } == true)
        XCTAssertTrue(updatedManifest.workbookRevisions?.contains { $0.role == .imported } == true)
    }

    func testImportRejectsNonXLSXWithoutChangingManifestOrCurrentWorkbook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let invalidURL = root.appendingPathComponent("not-a-workbook.txt")
        try Data("not a workbook".utf8).write(to: invalidURL)
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL)
        let originalCurrent = try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL))

        XCTAssertThrowsError(
            try GenotypeWorkbookRevisionService().importRevisedWorkbook(
                from: invalidURL,
                into: fixture.bundleURL,
                label: "bad"
            )
        )

        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: fixture.bundleURL), originalManifest)
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)),
            originalCurrent
        )
    }

    func testImportSnapshotsExternalEditBeforeManagedReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeBundle(in: root, outputName: "cohort", includeCurrent: true)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: fixture.bundleURL)
        try workbookData("manual direct edit").write(to: currentURL)
        let importedURL = root.appendingPathComponent("replacement.xlsx")
        try workbookData("replacement").write(to: importedURL)

        let updatedManifest = try GenotypeWorkbookRevisionService(
            dateProvider: { Date(timeIntervalSince1970: 3_600) },
            userProvider: { "tester" }
        ).importRevisedWorkbook(from: importedURL, into: fixture.bundleURL, label: "Replacement")

        let externalSnapshot = try XCTUnwrap(updatedManifest.workbookRevisions?.first { revision in
            revision.role == .externalEditSnapshot
                && revision.path.hasPrefix("artifacts/workbooks/revisions/")
        })
        XCTAssertEqual(
            try Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(for: externalSnapshot.path, in: fixture.bundleURL)),
            workbookData("manual direct edit")
        )
        XCTAssertEqual(try Data(contentsOf: currentURL), workbookData("replacement"))
    }

    private func makeBundle(
        in root: URL,
        outputName: String,
        includeCurrent: Bool
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        try workbookData("primary").write(to: primaryWorkbookURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)

        let currentWorkbookPath: String?
        let revisions: [ONTGenotypeWorkbookRevision]?
        if includeCurrent {
            let currentURL = bundleURL
                .appendingPathComponent("artifacts/workbooks", isDirectory: true)
                .appendingPathComponent("current.xlsx")
            try FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try workbookData("current").write(to: currentURL)
            currentWorkbookPath = "artifacts/workbooks/current.xlsx"
            revisions = [
                ONTGenotypeWorkbookRevision(
                    id: "initial-current-copy",
                    role: .initialCurrentCopy,
                    path: "artifacts/workbooks/current.xlsx",
                    label: "Initial editable workbook",
                    sourceFilename: primaryWorkbookURL.lastPathComponent,
                    createdAt: "2026-06-02T00:00:00Z",
                    user: "tester",
                    predecessorPath: primaryWorkbookURL.lastPathComponent,
                    sha256: try ProvenanceFileHasher.sha256(of: currentURL),
                    sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
                    provenancePath: nil
                )
            ]
        } else {
            currentWorkbookPath = nil
            revisions = nil
        }

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func writeMinimalNativeArtifacts(
        in bundleURL: URL,
        outputName: String
    ) throws -> (genotypeCSV: URL, sampleCSV: URL, statsJSON: URL, provenance: URL) {
        let genotypeCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
        let sampleCSVURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-samples.csv")
        let statsJSONURL = bundleURL.appendingPathComponent("\(outputName).retained-demux-stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        try Data("{}".utf8).write(to: provenanceURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads
        SampleA,allele1,1,1
        """.write(to: genotypeCSVURL, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads
        SampleA,1,1
        """.write(to: sampleCSVURL, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1,
          "totalAlignments": 1,
          "passedAlignments": 1,
          "retainedUniqueReads": 1,
          "retainedUniquePercentOfTotalReads": 100.0,
          "assignedUniqueRetainedReads": 1,
          "unassignedUniqueRetainedReads": 0
        }
        """.write(to: statsJSONURL, atomically: true, encoding: .utf8)
        return (genotypeCSVURL, sampleCSVURL, statsJSONURL, provenanceURL)
    }

    private func makeMCMWorkbookBundle(
        in root: URL,
        outputName: String
    ) throws -> (bundleURL: URL, manifest: ONTGenotypeResultBundleManifest) {
        let bundleURL = root.appendingPathComponent("\(outputName).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let primaryWorkbookURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalMCMWorkbook(at: primaryWorkbookURL)
        try FileManager.default.copyItem(at: primaryWorkbookURL, to: currentURL)
        let artifacts = try writeMinimalNativeArtifacts(in: bundleURL, outputName: outputName)
        let currentRevision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryWorkbookURL.lastPathComponent,
            createdAt: "2026-06-02T00:00:00Z",
            user: "tester",
            predecessorPath: primaryWorkbookURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [currentRevision],
            longSummaryCSVPath: artifacts.genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: artifacts.sampleCSV.lastPathComponent,
            statsJSONPath: artifacts.statsJSON.lastPathComponent,
            provenancePath: artifacts.provenance.lastPathComponent
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return (bundleURL, manifest)
    }

    private func makeMinimalMCMWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook

path = sys.argv[1]
wb = Workbook()
guide = wb.active
guide.title = "Interpretation Guide"
guide.append(["Field", "Interpretation"])
guide.append(["Haplotype min reads", "10"])

abbr = wb.create_sheet("Abbreviated Haplotypes")
headers = [
    "Client ID", "GS ID", "Mapped Read Count", "Haplotype 1", "Haplotype 2", None,
    "MHC-A Haplotype 1", "MHC-B Haplotype 1", "MHC-DRB Haplotype 1", "MHC-DQA/B Haplotype 1", "MHC-DPA/B Haplotype 1",
    None,
    "MHC-A Haplotype 2", "MHC-B Haplotype 2", "MHC-DRB Haplotype 2", "MHC-DQA/B Haplotype 2", "MHC-DPA/B Haplotype 2",
    "Comments",
]
abbr.append(headers)
abbr.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", "M4DR", "M4DQ", "M4DP", None, "M7A", "M7B", "M7DR", "M7DQ", "M7DP", None])

full = wb.create_sheet("Full Sequencing Results 1")
full.cell(1, 1).value = "Client ID"
full.cell(1, 4).value = "DW472"
full.cell(2, 1).value = "GS ID"
full.cell(2, 4).value = "DW472"
full.cell(3, 1).value = "Mapped Read Count"
full.cell(3, 4).value = 100
for row, label in enumerate([
    "MHC-A Haplotype 1", "MHC-A Haplotype 2",
    "MHC-B Haplotype 1", "MHC-B Haplotype 2",
    "MHC-DRB Haplotype 1", "MHC-DRB Haplotype 2",
    "MHC-DQA Haplotype 1", "MHC-DQA Haplotype 2",
    "MHC-DQB Haplotype 1", "MHC-DQB Haplotype 2",
    "MHC-DPA Haplotype 1", "MHC-DPA Haplotype 2",
    "MHC-DPB Haplotype 1", "MHC-DPB Haplotype 2",
    "Comments",
], start=4):
    full.cell(row, 1).value = label
    full.cell(row, 4).value = "old"

custom = wb.create_sheet("Custom Sort")
custom.append(headers)
custom.append(["MHC heterozygous  MCM animals"] + [None for _ in headers[1:]])
custom.append(["DW472", "DW472", 100, "M4", "M7", None, "M4A", "M4B", "M4DR", "M4DQ", "M4DP", None, "M7A", "M7B", "M7DR", "M7DQ", "M7DP", None])
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectMCMWorkbook(_ url: URL) throws -> [String: String] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)

def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value:
            values[str(value)] = col
    return values

def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == sample:
            return row
    return None

def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if ws.cell(row, col).value == sample:
                return col
    return None

def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

def guide_value(label):
    guide = wb["Interpretation Guide"]
    row = row_for(guide, label)
    return None if row is None else guide.cell(row, 2).value

abbr = wb["Abbreviated Haplotypes"]
custom = wb["Custom Sort"]
full = wb["Full Sequencing Results 1"]
abbr_headers = header_map(abbr)
custom_headers = header_map(custom)
abbr_row = sample_row(abbr, "DW472")
custom_row = sample_row(custom, "DW472")
full_col = sample_col(full, "DW472")
payload = {
    "abbreviatedDPHaplotype1": abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 1"]).value,
    "abbreviatedDPHaplotype2": abbr.cell(abbr_row, abbr_headers["MHC-DPA/B Haplotype 2"]).value,
    "customDPHaplotype1": custom.cell(custom_row, custom_headers["MHC-DPA/B Haplotype 1"]).value,
    "fullDPAHaplotype1": full.cell(row_for(full, "MHC-DPA Haplotype 1"), full_col).value,
    "fullDPBHaplotype2": full.cell(row_for(full, "MHC-DPB Haplotype 2"), full_col).value,
    "guideWorkbookUpdateSource": guide_value("Workbook update source"),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    private func pythonCanImportOpenpyxl() -> Bool {
        (try? runPython(["-c", "import openpyxl"])) != nil
    }

    private func runPython(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GenotypeWorkbookRevisionServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }
        return out
    }

    private func workbookData(_ label: String) -> Data {
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data(label.utf8))
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookRevisionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
