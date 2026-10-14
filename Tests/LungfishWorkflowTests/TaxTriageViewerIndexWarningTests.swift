// TaxTriageViewerIndexWarningTests.swift - The warning of a TaxTriage result whose viewer index could not be built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane U34, panel W4. An index that cannot be built is one sentence on every route, the sentence the
// app's row logs for a result it builds in process, `The viewer index could not be built (<error>). LGE builds it
// when the result opens.` The TaxTriage executor wrote `The viewer index could not be built: <error>. The viewer
// builds it when the result opens.` These cases call `TaxTriageAnalysisRunTool.finalize(_:context:)` alone, with an
// index builder that fails and no unit, so the finalize reaches the index and nothing else.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageViewerIndexWarningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-index-warning").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAnIndexThatCannotBeBuiltIsTheSentenceEveryRouteLogs() async throws {
        let batch = root.appendingPathComponent("Project.lungfish/Analyses/taxtriage-batch-2026-10-13T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let sample = TaxTriageSample(sampleId: "A", fastq1: root.appendingPathComponent("A.fastq"))
        let tool = TaxTriageAnalysisRunTool(
            request: TaxTriageRunRequest(settings: TaxTriageConfig(samples: [sample], outputDirectory: batch))
        )
        let context = AnalysisRunFinalizeContext(
            rootDirectory: batch,
            layout: .batchRoot,
            projectURL: nil,
            toolID: .taxtriage,
            indexing: FailingIndexer()
        )

        let finalization = try await tool.finalize([], context: context)

        XCTAssertEqual(
            finalization.warnings,
            ["The viewer index could not be built (disk full). LGE builds it when the result opens."]
        )
    }

    /// An index builder that cannot build, as a full disk stops the `build-db taxtriage` core.
    private struct FailingIndexer: AnalysisResultIndexing {
        struct Failure: LocalizedError {
            var errorDescription: String? { "disk full" }
        }

        func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
            throw Failure()
        }
    }
}
