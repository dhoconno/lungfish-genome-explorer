// EsVirituImportedFolderSidebarTests.swift - A person can reach an imported EsViritu folder in the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// Row IMPORT-ESVIRITU-FLAT-BATCH-HIDDEN. A flat folder of EsViritu output (hand built, or a batch whose sample folders are
/// gone) that carries a batch mark must still show in the sidebar after it is imported. The sidebar lists a classifier
/// batch only with a batch manifest or sample folders that hold a result, and skips the rest as an empty batch.
final class EsVirituImportedFolderSidebarTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-flat-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
    }

    func testAFlatFolderWithABatchMarkIsListedInTheSidebarAfterImport() throws {
        let source = try flatSource(batchMark: true)
        let (project, imported) = try importIntoProject(source)

        XCTAssertTrue(
            listed(imported, in: project),
            "The imported folder is hidden from the sidebar, so the person cannot reach the result they just imported."
        )
    }

    /// The control. The same folder with no batch mark is listed, so a miss above is the batch mark and not the setup.
    func testTheSameFolderWithoutABatchMarkIsListedInTheSidebarAfterImport() throws {
        let source = try flatSource(batchMark: false)
        let (project, imported) = try importIntoProject(source)

        XCTAssertTrue(listed(imported, in: project))
    }

    // MARK: - Helpers

    private func flatSource(batchMark: Bool) throws -> URL {
        let source = workspace.appendingPathComponent(batchMark ? "esv-flat-batch" : "esv-flat", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if batchMark {
            try AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(tool: "esviritu", isBatch: true),
                to: source
            )
        }
        let detection = [
            "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample",
            "SampleA\tExample virus\tExample description\t1000\t\tACCN0001\tGCF_000001\t1000\tViruses\t\t\t\tExampleviridae\tExamplevirus\tExample virus species\t\t1.5\t42\t900\t12.4\t97.2\t0.01\t10000",
        ].joined(separator: "\n")
        try detection.write(
            to: source.appendingPathComponent("SampleA.detected_virus.info.tsv"), atomically: true, encoding: .utf8
        )
        return source
    }

    /// Imports into the `Analyses` folder of a project, where the Import Center puts a result.
    private func importIntoProject(_ source: URL) throws -> (project: URL, imported: EsVirituImportResult) {
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let imported = try MetagenomicsImportService.importEsViritu(inputURL: source, outputDirectory: analyses)
        return (project, imported)
    }

    private func listed(_ imported: EsVirituImportResult, in project: URL) -> Bool {
        SidebarProjectScanner.collectAnalyses(in: project).contains {
            $0.url?.lastPathComponent == imported.resultDirectory.lastPathComponent
        }
    }
}
