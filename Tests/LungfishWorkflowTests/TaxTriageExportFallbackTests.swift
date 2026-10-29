// TaxTriageExportFallbackTests.swift - What File > Export > Provenance holds when nothing is selected
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B13, row 257 of the Phase 2.8 plan. With nothing selected the app exports the latest completed run the
// recorder still holds (`AppDelegate.exportProvenance`), as the record its save writes. A TaxTriage run begins with
// every option of its record as a parameter, and its save files the database identity, the plan of a record of one
// sample and `classifiers` among the resolved defaults (`TaxTriageRecordFacts.recordOptions`). The recorder used to
// forget the options a save passed, so the fallback filed those values as explicit options. They were true and their
// home was wrong. These tests run the pipeline on `TaxTriageStandInEngine` and read the fallback beside the record the
// save wrote, and show the recorder rule alone with no TaxTriage in it.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageExportFallbackTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-export-fallback")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    /// The keys a one-sample TaxTriage record holds among its resolved defaults when its sample has a plan. Moved by
    /// A2 M3 (B12 ruling H1): `sample_count` is one too, because LGE counts the samplesheet rows itself.
    private static let resolvedKeys: Set<String> = ["fetchedReferences", 
        "classifiers", "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes", RecordedReadSetPlan.key,
        "sample_count",
    ]

    /// A Kraken 2 database folder with its three core files, which the stand-in never reads.
    private func makeDatabase() throws -> URL {
        let folder = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, bytes) in [("hash.k2d", 11), ("opts.k2d", 7), ("taxo.k2d", 5)] {
            try Data(repeating: 0x2A, count: bytes).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// The fallback's record of the run `id`, which is the run the recorder kept when its save ended.
    private func fallbackRecord(of id: UUID) async throws -> ProvenanceEnvelope {
        let envelopes = await ProvenanceRecorder.shared.canonicalEnvelopes()
        return try XCTUnwrap(envelopes.first { $0.id == id }, "the recorder still holds the run it just saved")
    }

    // MARK: - Row 257, a one-sample TaxTriage run

    /// The fallback after a run of one sample that has a plan files the Kraken 2 database identity, the plan and
    /// `classifiers` among the resolved defaults, and keeps them out of the explicit options, as the saved record does.
    func testTheFallbackFilesTheDatabaseIdentityAndThePlanAsTheSavedRecordDoes() async throws {
        let engine = try TaxTriageStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true))
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let planned = try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: "mixed", fastq1: fixtures.mixedRoot),
            materializationDirectory: root.appendingPathComponent("inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
        XCTAssertNotNil(planned.readSetPlan?.singleReadReason, "a bundle that mixes pairs and single reads has a plan")
        let config = TaxTriageConfig(
            samples: [planned],
            outputDirectory: root.appendingPathComponent("run", isDirectory: true),
            kraken2DatabasePath: try makeDatabase(),
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )

        _ = try await engine.makePipeline().run(config: config)

        let saved = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: config.outputDirectory))
        let fallback = try await fallbackRecord(of: saved.id)
        XCTAssertEqual(Set(saved.options.resolvedDefaults.keys), Self.resolvedKeys, "the saved record's homes")
        XCTAssertEqual(Set(fallback.options.resolvedDefaults.keys), Self.resolvedKeys)
        XCTAssertEqual(Set(fallback.options.explicit.keys), Set(saved.options.explicit.keys))
        XCTAssertTrue(
            Self.resolvedKeys.isDisjoint(with: fallback.options.explicit.keys),
            "no database identity, plan or classifiers among the explicit options"
        )
        XCTAssertEqual(fallback.options.resolvedDefaults["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(
            fallback.options.resolvedDefaults["databaseCoreFileSizes"],
            .dictionary(["hash.k2d": .integer(11), "opts.k2d": .integer(7), "taxo.k2d": .integer(5)])
        )
        XCTAssertEqual(
            fallback.options.resolvedDefaults[RecordedReadSetPlan.key],
            TaxTriageRecordFacts(config: config).resolvedDefaults[RecordedReadSetPlan.key],
            "the plan the sample was planned with"
        )
        XCTAssertEqual(fallback.options.defaults, saved.options.defaults)
    }

    // MARK: - The recorder rule

    /// The fallback is the record the latest save wrote. A run not saved yet has its parameters as explicit options,
    /// a save that passes options files them where the save did, and a later save with none leaves the parameters
    /// explicit again.
    func testTheFallbackIsTheRecordTheLatestSaveWrote() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(
            name: "Fallback",
            parameters: ["limit": .integer(5), "databasePath": .string("/db"), "mode": .string("fast")]
        )
        await recorder.recordStep(
            runID: runID, toolName: "tool", toolVersion: "1.0", command: ["tool"],
            inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )
        await recorder.completeRun(runID, status: .completed)

        func fallbackOptions() async throws -> ProvenanceOptions {
            let envelopes = await recorder.canonicalEnvelopes()
            return try XCTUnwrap(envelopes.first { $0.id == runID }).options
        }
        let before = try await fallbackOptions()
        XCTAssertEqual(Set(before.explicit.keys), ["limit", "databasePath", "mode"], "nothing saved yet")
        XCTAssertTrue(before.resolvedDefaults.isEmpty)

        let options = ProvenanceOptions(resolvedDefaults: ["databasePath": .string("/db")])
        try await recorder.save(runID: runID, to: root.appendingPathComponent("first", isDirectory: true), options: options)
        let saved = try await fallbackOptions()
        XCTAssertEqual(Set(saved.explicit.keys), ["limit", "mode"])
        XCTAssertEqual(saved.resolvedDefaults, ["databasePath": .string("/db")])
        let written = try XCTUnwrap(
            ProvenanceEnvelopeReader.loadCanonical(from: root.appendingPathComponent("first", isDirectory: true))
        )
        XCTAssertEqual(saved, written.options, "the options the save wrote")

        try await recorder.save(runID: runID, to: root.appendingPathComponent("second", isDirectory: true))
        let again = try await fallbackOptions()
        XCTAssertEqual(Set(again.explicit.keys), ["limit", "databasePath", "mode"], "the latest save passed no options")
        XCTAssertTrue(again.resolvedDefaults.isEmpty)
    }

    /// A save that drops the run-level files that no longer exist, as Kraken 2's save does after it removes its raw
    /// output, leaves the removed file out of the fallback's `files` and `outputs` too. The step keeps its record.
    func testTheFallbackDropsTheRunLevelFilesTheSaveDropped() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Fallback drop", parameters: ["limit": .integer(5)])
        let raw = root.appendingPathComponent("raw.txt")
        try Data("raw output".utf8).write(to: raw)
        await recorder.recordStep(
            runID: runID, toolName: "tool", toolVersion: "1.0", command: ["tool"],
            inputs: [],
            outputs: [FileRecord(path: raw.path, format: .text, role: .output)],
            exitCode: 0, wallTime: 1
        )
        await recorder.completeRun(runID, status: .completed)

        func fallback() async throws -> ProvenanceEnvelope {
            let envelopes = await recorder.canonicalEnvelopes()
            return try XCTUnwrap(envelopes.first { $0.id == runID })
        }
        let unsaved = try await fallback()
        XCTAssertTrue(unsaved.outputs.contains { $0.path == raw.path }, "the run-level outputs list the file while it exists")

        try FileManager.default.removeItem(at: raw)
        let directory = root.appendingPathComponent("saved", isDirectory: true)
        try await recorder.save(runID: runID, to: directory, dropMissingRunLevelFiles: true)

        let written = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: directory))
        XCTAssertFalse(written.files.contains { $0.path == raw.path }, "the save dropped the removed file from the files")
        XCTAssertFalse(written.outputs.contains { $0.path == raw.path }, "the save dropped it from the outputs")
        XCTAssertTrue(written.steps.flatMap(\.outputs).contains { $0.path == raw.path }, "the step keeps its record")

        let exported = try await fallback()
        XCTAssertFalse(exported.files.contains { $0.path == raw.path }, "the fallback lists no file the save dropped")
        XCTAssertFalse(exported.outputs.contains { $0.path == raw.path }, "nor an output the save dropped")
        XCTAssertTrue(exported.steps.flatMap(\.outputs).contains { $0.path == raw.path }, "the step keeps its record")
    }
}
