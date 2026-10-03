// AssemblyProvenanceInputsOffMainTests.swift - Reassemble's input records leave the main thread unchanged
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// After the assembler finished, `AssemblyRunner.runManagedAssemblyOperation`
// built the input records and the materialization steps on the main
// thread. Both hash every input file, and every file of a joined bundle
// twice, so the app hung for minutes on a large ONT bundle (final review
// S2). They are now built by `managedAssemblyProvenanceInputs` on the
// concurrent executor (R10). The records it returns are byte-identical to
// the ones the main thread built, and the steps differ only in the random
// identifier every step takes when it is made, which differs between two
// main-thread runs as well. No case runs a tool.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class AssemblyProvenanceInputsOffMainTests: XCTestCase {
    private var root: URL!
    private var shapes: AssemblyBundleShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assembly-provenance-inputs-off-main")
        shapes = try AssemblyBundleShapes(in: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A virtual bundle that orients m1 and m4 of the multi-file root, so
    /// its records name both chunks.
    private func orientedOverMultiFileRoot() throws -> URL {
        let bundle = shapes.multiFile.deletingLastPathComponent()
            .appendingPathComponent("multi-oriented.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "m1\t+\nm4\t-\n".write(to: bundle.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try AssemblyBundleShapes.fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .orient)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "multi-oriented",
                parentBundleRelativePath: "@/Imports/multi.lungfishfastq",
                rootBundleRelativePath: "@/Imports/multi.lungfishfastq",
                rootFASTQFilename: "chunks/run_0.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// The inputs `runValidated` hands the pipeline for `inputs`, resolved
    /// the way the run resolves them.
    private func resolvedRun(_ inputs: [URL]) async throws -> AssemblyRunner.ManagedAssemblyMaterializationResult {
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: inputs,
            projectName: "reassembled",
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            threads: 1
        ).normalizedForExecution()
        let executionRequest = AssemblyRunner.executionRequest(for: request)
        return try await AssemblyRunner.materializedManagedAssemblyRequestResult(
            from: executionRequest,
            tempDirectory: executionRequest.outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materialize: { bundleURL, tempDirectory, progress in
                try await FASTQCLIMaterializer(runner: .shared).materialize(
                    bundleURL: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: progress
                )
            }
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// The steps' JSON without the random identifier each step takes when it is made.
    private func encodedWithoutIdentifiers(_ steps: [ProvenanceStep]) throws -> Data {
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoded(steps)) as? [[String: Any]])
        return try JSONSerialization.data(
            withJSONObject: objects.map { $0.filter { $0.key != "id" } },
            options: [.sortedKeys]
        )
    }

    func testTheRecordsBuiltOffTheMainThreadAreTheRecordsTheRunBuiltOnIt() async throws {
        let cases: [(shape: String, inputs: [URL], steps: Int)] = [
            ("joined multi-file bundle", [shapes.multiFile], 1),
            ("virtual bundle of a single-file root", [shapes.oriented], 1),
            ("virtual bundle of a multi-file root", [try orientedOverMultiFileRoot()], 1),
            ("mate pair", [shapes.paired], 0),
        ]
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let endedAt = Date(timeIntervalSince1970: 1_002)
        for testCase in cases {
            let run = try await resolvedRun(testCase.inputs)
            // What the run built on the main thread before.
            let mainThreadRecords = AssemblyRunner.managedAssemblyInputRecords(
                originalInputURLs: run.originalInputURLs,
                executionInputURLs: run.request.inputURLs
            )
            let mainThreadSteps = try AssemblyRunner.managedAssemblyMaterializationSteps(
                originalInputURLs: run.originalInputURLs,
                executionInputURLs: run.request.inputURLs,
                startedAt: startedAt,
                endedAt: endedAt
            )
            let offMain = try await AssemblyRunner.managedAssemblyProvenanceInputs(
                originalInputURLs: run.originalInputURLs,
                executionInputURLs: run.request.inputURLs,
                startedAt: startedAt,
                endedAt: endedAt
            )

            XCTAssertFalse(mainThreadRecords.isEmpty, testCase.shape)
            XCTAssertTrue(mainThreadRecords.allSatisfy { $0.sha256 != nil }, "\(testCase.shape): every record is hashed")
            XCTAssertEqual(try encoded(offMain.records), try encoded(mainThreadRecords), "\(testCase.shape): the records")
            XCTAssertEqual(mainThreadSteps.count, testCase.steps, testCase.shape)
            XCTAssertEqual(
                try encodedWithoutIdentifiers(offMain.steps),
                try encodedWithoutIdentifiers(mainThreadSteps),
                "\(testCase.shape): the steps"
            )
        }
    }
}
