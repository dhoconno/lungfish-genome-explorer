// NativeProjectCopyRehydrationCancellationTests.swift - The native copy takes a cancel while an item's own record is rehydrated
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS), fix round after the SWIFT review. An item that carries its own
// provenance record gets more passes over its files once the copy is published. The rehydrator checks each recorded
// output against the record and hashes it again for the rewritten record, so the copy's check must run in those
// passes too, or a cancel waits for them. Each test throws at the first check that runs once the item is published,
// so a rehydrator that takes no check lets the copy finish and the test fails. A sparse file of eight hash chunks
// stands for the large file, so the tests write almost nothing to disk.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class NativeProjectCopyRehydrationCancellationTests: XCTestCase {
    /// How many chunks of `FileDigest` the sparse file holds.
    private static let chunks = 8
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "native-copy-rehydration-cancel")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testACopyThatIsNotCancelledRehydratesTheRecordOfABundle() throws {
        // The control. The rehydrator maps the record's output onto the copy, which it can do only after it has read
        // the copy, and it keeps the source run in the history.
        let bundle = try makeBundle()
        let destination = bundleDestination()

        let published = try NativeProjectCopyImportService.copy(from: bundle, to: destination)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: published.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
        XCTAssertEqual(record.output?.path, published.appendingPathComponent("padding.bin").path, "the record names the copy")
        XCTAssertEqual(record.argv.first, "source-tool", "the copy keeps the command of the source run. \(record.argv)")
        XCTAssertTrue(record.steps.contains { $0.toolName == "lungfish-app" }, "the rehydrator added the import step")
    }

    func testACheckThatThrowsOnceTheBundleIsPublishedStopsTheRehydrationAndRollsTheCopyBack() throws {
        let bundle = try makeBundle()
        let destination = bundleDestination()
        var existedAtTheFirstCheck: Bool?
        var callsOnceCopied = 0

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: bundle, to: destination, checkCancellation: {
            if existedAtTheFirstCheck == nil { existedAtTheFirstCheck = FileManager.default.fileExists(atPath: destination.path) }
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("padding.bin").path) else { return }
            callsOnceCopied += 1
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(existedAtTheFirstCheck, false, "nothing sits at the destination before the copy is published")
        XCTAssertEqual(callsOnceCopied, 1, "the rehydration checks the cancel between the chunks of its first hash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the published copy is rolled back")
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    func testACheckThatThrowsOnceTheFileIsPublishedStopsTheRehydrationAndRollsTheCopyBack() throws {
        let file = try makeFile()
        let destination = root.appendingPathComponent("Target.lungfish/Documents/Big.bin")
        var existedAtTheFirstCheck: Bool?
        var callsOnceCopied = 0

        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: file, to: destination, checkCancellation: {
            if existedAtTheFirstCheck == nil { existedAtTheFirstCheck = FileManager.default.fileExists(atPath: destination.path) }
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
            callsOnceCopied += 1
            throw CancellationError()
        })) { error in
            XCTAssertTrue(error is CancellationError, "the cancel comes back as itself, not \(error)")
        }

        XCTAssertEqual(existedAtTheFirstCheck, false, "nothing sits at the destination before the copy is published")
        XCTAssertEqual(callsOnceCopied, 1, "the rehydration checks the cancel between the chunks of its first hash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the published copy is rolled back")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: destination).path),
            "no record is left beside the destination"
        )
        XCTAssertEqual(residue(beside: destination), [], "no .native-copy- folder is left")
    }

    /// Measured, not counted from the code: the hash of the source, the hash of the copy, the check against the record
    /// and three rewrites. With the forward of the check removed from the rewrite's hash the same count reads 3.
    private static let passesOverTheFile = 6

    func testTheRewriteOfTheRecordHashesTheCopyWithTheCheckToo() throws {
        // A larger sparse file adds one check per chunk to every pass over it, so the difference counts the passes.
        let small = try countChecks(ofACopyWithASparseFileOf: 2, in: "Small")
        let large = try countChecks(ofACopyWithASparseFileOf: 6, in: "Large")
        XCTAssertEqual((large - small) % (6 - 2), 0, "whole passes only")
        XCTAssertEqual(
            (large - small) / (6 - 2), Self.passesOverTheFile,
            "the hash of the source, the hash of the copy, the check against the record and the three rewrites check the cancel"
        )
    }

    private func countChecks(ofACopyWithASparseFileOf chunks: Int, in folder: String) throws -> Int {
        let bundle = root.appendingPathComponent("\(folder)/Source/Big.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let sparse = bundle.appendingPathComponent("padding.bin")
        try makeSparseFile(at: sparse, chunks: chunks)
        try ProvenanceWriter(signingProvider: nil).write(try record(naming: sparse), to: bundle)
        var total = 0
        _ = try NativeProjectCopyImportService.copy(
            from: bundle, to: root.appendingPathComponent("\(folder)/Target/Big.lungfishref", isDirectory: true),
            checkCancellation: { total += 1 }
        )
        return total
    }

    // MARK: - Fixture

    /// A reference bundle whose record names one sparse file of `chunks` hash chunks. The bundle sits outside a
    /// project, so its record keeps absolute paths. Inside a project the writer makes them project-relative, the
    /// project of the copy resolves them onto itself, and the rehydrator then finds no output under the source.
    private func makeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Source/Big.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let sparse = bundle.appendingPathComponent("padding.bin")
        try makeSparseFile(at: sparse)
        try ProvenanceWriter(signingProvider: nil).write(try record(naming: sparse), to: bundle)
        return bundle
    }

    /// A file item whose record sits beside it as a sidecar.
    private func makeFile() throws -> URL {
        let folder = root.appendingPathComponent("Source.lungfish/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sparse = folder.appendingPathComponent("Big.bin")
        try makeSparseFile(at: sparse)
        try ProvenanceWriter(signingProvider: nil).write(
            try record(naming: sparse), toSidecar: ProvenanceRecorder.fileSidecarURL(for: sparse)
        )
        return sparse
    }

    private func makeSparseFile(at url: URL, chunks: Int = NativeProjectCopyRehydrationCancellationTests.chunks) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(chunks * FileDigest.defaultChunkSize))
        try handle.close()
    }

    /// The record of a source run that made `output`, built as the CLI builds one.
    private func record(naming output: URL) throws -> ProvenanceEnvelope {
        try ProvenanceRunBuilder(
            workflowName: "source item", workflowVersion: "1.0", toolName: "source-tool", toolVersion: "1.0"
        )
        .argv(["source-tool", output.path])
        .output(output, format: .unknown, role: .output)
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
    }

    private func bundleDestination() -> URL {
        root.appendingPathComponent("Target/Big.lungfishref", isDirectory: true)
    }

    /// The `.native-copy-` folders beside `destination`.
    private func residue(beside destination: URL) -> [String] {
        let folder = destination.deletingLastPathComponent().path
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(".native-copy-") }
    }
}
