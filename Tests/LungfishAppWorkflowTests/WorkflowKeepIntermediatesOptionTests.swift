import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class WorkflowKeepIntermediatesOptionTests: XCTestCase {
    func testAmpliconRequestDefaultsToCleanupAndReplaysExplicitKeep() {
        let base = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            referenceSourceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/result", isDirectory: true)
        )
        XCTAssertFalse(base.keepIntermediates)
        XCTAssertFalse(base.argv.contains("--keep-intermediates"))

        let retained = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: base.inputFASTQURLs,
            referenceSourceURL: base.referenceSourceURL,
            outputDirectory: base.outputDirectory,
            keepIntermediates: true
        )
        XCTAssertTrue(retained.keepIntermediates)
        XCTAssertTrue(retained.argv.contains("--keep-intermediates"))
    }

    func testDialogExposesKeepOnlyForTheTwoMHCGenotypingWorkflows() throws {
        let sourceURL = packageRoot()
            .appendingPathComponent(
                "Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(
            source.components(separatedBy: "Toggle(\"Keep Intermediates\"").count - 1,
            2
        )
        XCTAssertTrue(source.contains("Off is recommended for normal runs."))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
