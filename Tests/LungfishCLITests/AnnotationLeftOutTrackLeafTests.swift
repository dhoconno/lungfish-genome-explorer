// AnnotationLeftOutTrackLeafTests.swift - The table leaf and convert's JSON name the annotation tracks they could not read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-2 (BIO-EXPORT-MISSING-TRACK-17 rows 4 and 2). `bundle export-annotation-table` wrote the rows of the
// tracks it could read with no word of the one it could not, and `convert --format json`, which the app's GenBank
// export reads, carried no word of it either. Each now names the left-out track: the table leaf in its completion
// message, one standard error line and its record's `left_out_tracks`, and convert in its JSON summary.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Reads what `body` writes to the process's standard error, so a test can see the lines a leaf prints.
enum StandardErrorCapture {
    static func run<T>(_ body: () async throws -> T) async throws -> (value: T, standardError: String) {
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let value: T
        do {
            value = try await body()
        } catch {
            dup2(saved, STDERR_FILENO)
            close(saved)
            try? pipe.fileHandleForWriting.close()
            throw error
        }
        dup2(saved, STDERR_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (value, String(decoding: data, as: UTF8.self))
    }
}

final class AnnotationLeftOutTrackLeafTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "annotation-left-out-leaf")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Row 4, bundle export-annotation-table

    private func tableCommand(bundle: URL, identities: [String], output: URL) throws -> BundleExportAnnotationTableSubcommand {
        let selection = try AnnotationTableExportStreamCapture.annotationSelection(identities: identities)
            .write(besideOutput: output)
        let parsed = try LungfishCLI.parseAsRoot([
            "bundle", "export-annotation-table", bundle.path, "--tab", "annotations", "--output-format", "tsv",
            "--selection", selection.path, "-o", output.path,
        ])
        return try XCTUnwrap(parsed as? BundleExportAnnotationTableSubcommand)
    }

    func testTableLeafOfABundleWithOneMissingDatabaseWritesTheOtherRowsAndNamesTheMissingTrack() async throws {
        let bundle = try AnnotationLeftOutTrackCLITests.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("NG-4tracks.tsv")
        let command = try tableCommand(bundle: bundle, identities: ["track-a:1", "track-b:1", "track-d:1"], output: output)

        let run = try await StandardErrorCapture.run { try await command.export() }

        XCTAssertEqual(
            run.value.message,
            "Exported 3 rows to NG-4tracks.tsv. 1 annotation track is not in this table, because its annotation "
                + "database is missing or cannot be read: two-parent c. "
                + "Reopen the bundle, and if this repeats, import those annotations again."
        )
        XCTAssertTrue(
            run.standardError.contains(
                "warning: two-parent c: its annotation database is missing or cannot be read, so its annotations are not in this table."
            ),
            "one standard error line names the missing track. \(run.standardError)"
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.resolvedDefaults["left_out_tracks"], .array([.string("two-parent c")]))
    }

    /// A bundle that reads every database keeps the leaf's own words and its record's keys.
    func testTableLeafOfAHealthyBundleKeepsItsWordsAndWritesNoLeftOutKey() async throws {
        let bundle = try AnnotationLeftOutTrackCLITests.makeBundle(in: root, removing: [])
        let output = root.appendingPathComponent("healthy.tsv")
        let command = try tableCommand(bundle: bundle, identities: ["track-a:1"], output: output)

        let run = try await StandardErrorCapture.run { try await command.export() }

        XCTAssertEqual(run.value.message, "Exported 1 row to healthy.tsv")
        XCTAssertFalse(run.standardError.contains("warning:"), run.standardError)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertNil(envelope.options.resolvedDefaults["left_out_tracks"])
    }

    // MARK: - Row 2, the JSON the app's GenBank export reads

    /// The app's export runs `convert ... --format json --quiet` and reads the JSON on standard output, so the
    /// left-out track has to be named there for the app's completion to say so.
    func testConvertJSONOfABundleWithOneMissingDatabaseNamesTheMissingTrack() throws {
        let bundle = try AnnotationLeftOutTrackCLITests.makeBundle(in: root, removing: ["track-c"])
        let output = root.appendingPathComponent("NG-4tracks.gb")

        let run = try runCLI([
            "convert", bundle.path, "--to", output.path, "--to-format", "genbank", "--include-annotations",
            "--force", "--format", "json", "--quiet",
        ])

        XCTAssertEqual(run.status, 0, "the conversion still writes. \(run.stdout) \(run.stderr)")
        struct Summary: Decodable {
            let sequenceCount: Int
            let leftOutTracks: [AnnotationDatabase.LeftOutTrack]?
        }
        let json = Data(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let summary = try JSONDecoder().decode(Summary.self, from: json)
        XCTAssertEqual(summary.sequenceCount, 1)
        XCTAssertEqual(summary.leftOutTracks?.map(\.name), ["two-parent c"], "the JSON names the missing track. \(run.stdout)")
    }

    /// Runs the built lungfish-cli and returns its exit status, standard output and standard error.
    private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: Self.self),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: [:])
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
