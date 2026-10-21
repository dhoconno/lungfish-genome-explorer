// ClassifierReadExtractionRouteParityTests.swift - The classifier read extraction saved to a file against extract reads --by-classifier
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27 c6 and c7, V1-6 (MD73 (c), MD76). The sheet's Save to File runs `ClassifierReadResolver` in process and
// records the file with the app's name. Its record may name `lungfish-cli extract reads --by-classifier` as its durable replay
// argv only if that leaf writes the same bytes from the same fixture. This class makes that proof. Side A is the app's
// run, the options `TaxonomyReadExtractionAction` builds for a file destination and the resolver call its closure makes.
// Side C is the leaf, run in this process from the command the row records for the same extraction. No side launches the
// CLI, so the class stays in the unit tier. The last assertions read the record each side wrote beside its file and hold the
// app's durable replay argv and command equal to the leaf's own argv and command, with the two roots masked.

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

    /// One Kraken2 selection, taxon 20 of the single-end fixture, saved to a file by each route. The two files are byte-equal,
    /// and the app's record replays the leaf's command.
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

        // The record each side wrote beside its file. The app's names what ran and replays the leaf's command.
        let app = try Self.replayWords(of: outputA)
        let leafRecord = try Self.replayWords(of: outputC)
        XCTAssertEqual(leafRecord.argv.first, CLICommandIdentity.executableName)
        XCTAssertEqual(app.argv.first, LungfishAppIdentity.recordedToolName, "argv names what ran")
        XCTAssertEqual(app.durableReplayArgv, leafRecord.argv, "the run's durable replay argv is the leaf's argv")
        XCTAssertEqual(app.stepDurableReplayArgv, leafRecord.argv, "the step's durable replay argv is the leaf's argv")
        XCTAssertEqual(app.reproducibleCommand, leafRecord.reproducibleCommand, "the run's command agrees with its replay line")
        XCTAssertEqual(app.stepReproducibleCommand, leafRecord.stepReproducibleCommand, "the step's command agrees with its replay line")
    }

    /// What a record says it replays, with the side's folder (`scratch/a` or `scratch/c`) written `<ROOT>`, so the two sides compare.
    private struct ReplayWords {
        let argv: [String]
        let durableReplayArgv: [String]
        let stepDurableReplayArgv: [String]
        let reproducibleCommand: String
        let stepReproducibleCommand: String
    }

    private static func replayWords(of output: URL) throws -> ReplayWords {
        let record = URL(fileURLWithPath: output.path + ".lungfish-provenance.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let step = try XCTUnwrap((json["steps"] as? [[String: Any]])?.first)
        let root = output.deletingLastPathComponent()
        let spellings = [root.resolvingSymlinksInPath().path, root.standardizedFileURL.path, root.path].sorted { $0.count > $1.count }
        func masked(_ text: String) -> String { spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: "<ROOT>") } }
        func words(_ value: Any?) -> [String] { ((value as? [String]) ?? []).map(masked) }
        return ReplayWords(
            argv: words(json["argv"]), durableReplayArgv: words(json["durableReplayArgv"]),
            stepDurableReplayArgv: words(step["durableReplayArgv"]),
            reproducibleCommand: masked(json["reproducibleCommand"] as? String ?? ""),
            stepReproducibleCommand: masked(step["reproducibleCommand"] as? String ?? "")
        )
    }
}
