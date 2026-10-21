// ClassifierReadExtractionRouteParityTests.swift - The classifier read extraction saved to a file against extract reads --by-classifier
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27 c6, V1-6 (MD73 (c)). The sheet's Save to File runs `ClassifierReadResolver` in process and records
// the file with the app's name. Its record may name `lungfish-cli extract reads --by-classifier` as its durable replay
// argv only if that leaf writes the same bytes from the same fixture. This class makes that proof. Side A is the app's
// run, the options `TaxonomyReadExtractionAction` builds for a file destination and the resolver call its closure makes.
// Side C is the leaf, run in this process from the command the row records for the same extraction. No side launches the
// CLI, so the class stays in the unit tier. The assertions about the record's `durableReplayArgv` join this test with the
// change that sets it (the c6 report, Handoff).

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ClassifierReadExtractionRouteParityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "classifier-file-parity")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// One Kraken2 selection, taxon 20 of the single-end fixture, saved to a file by each route. The two files are byte-equal.
    func testClassifierReadExtractionFileInProcessRunAndLeafWriteEqualBytes() async throws {
        let fixtures = try TaxaCollectionFixtures(in: scratch.appendingPathComponent("fixture", isDirectory: true))
        let context = TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: fixtures.singleEnd,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [TaxaCollectionFixtures.speciesB])],
            suggestedName: "my-extract",
            routeContext: nil
        )
        let dialogOptions = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let outputA = scratch.appendingPathComponent("a", isDirectory: true).appendingPathComponent("out.fastq")
        let outputC = scratch.appendingPathComponent("c", isDirectory: true).appendingPathComponent("out.fastq")
        for output in [outputA, outputC] {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        // The app's run, as startExtraction makes it for a file destination.
        let destination = ExtractionDestination.file(outputA)
        let options = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            dialogOptions, context: context, destination: destination
        )
        _ = try await ClassifierReadResolver().resolveAndExtract(
            tool: context.tool, resultPath: context.resultPath, selections: context.selections,
            options: options, destination: destination
        )

        // The leaf, from the command the row records for the same extraction. The leaf reads its selections from the
        // raw words, as the invariant tests' round trip passes them.
        let command = TaxonomyReadExtractionAction.buildCLIString(context: context, options: dialogOptions, destination: .file(outputC))
        let words = Array(try RecordedCLICommand.arguments(of: command).dropFirst(2))
        var leaf = try ExtractReadsSubcommand.parse(words)
        leaf.testingRawArgs = words
        try leaf.validate()
        try await leaf.run()

        XCTAssertEqual(
            try Data(contentsOf: outputA), try Data(contentsOf: outputC),
            "the app's extraction and extract reads --by-classifier write different bytes"
        )
        XCTAssertFalse(try Data(contentsOf: outputA).isEmpty, "the extraction wrote no reads")
    }
}
