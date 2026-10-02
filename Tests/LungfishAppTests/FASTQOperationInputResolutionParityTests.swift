// FASTQOperationInputResolutionParityTests.swift - The dialog's one-file resolution of a bundle is the materializer's
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog used to resolve a bundle to the one file a
// `fastq` subcommand reads with its own rules (the primary file of a
// single-file bundle, its own byte join of a multi-file bundle, the
// materializer for a derived bundle). It now resolves every bundle through
// FASTQCLIMaterializer, the resolution the dashboard's in-process derivative
// and a `fastq` subcommand given a bundle share, so one implementation
// decides what a bundle means (R3, lane 1x). The old rules live here as the
// reference, and each bundle shape resolves to the same bytes either way.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQOperationInputResolutionParityTests: XCTestCase {
    private var root: URL!
    private var shapes: AssemblyBundleShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-input-resolution-parity")
        shapes = try AssemblyBundleShapes(in: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The dialog's resolution before lane 1x, kept verbatim as the reference.
    private func legacyResolution(of inputURL: URL, tempDirectory: URL) async throws -> URL {
        let standardizedInputURL = inputURL.standardizedFileURL
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInputURL) {
            if FASTQBundle.isDerivedBundle(bundleURL) {
                return try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                    fromBundle: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: nil
                )
            }
            if let allFASTQURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), allFASTQURLs.count > 1 {
                let outputURL = tempDirectory.appendingPathComponent(FASTQSourceResolver.tempFileName(extension: "fastq"))
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                defer { try? outputHandle.close() }
                for memberURL in allFASTQURLs {
                    let inputHandle = try FileHandle(forReadingFrom: memberURL)
                    defer { try? inputHandle.close() }
                    while true {
                        let chunk = inputHandle.readData(ofLength: 1_048_576)
                        if chunk.isEmpty { break }
                        outputHandle.write(chunk)
                    }
                }
                return outputURL
            }
            if let primarySequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL) {
                return primarySequenceURL
            }
        }
        if let primarySequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedInputURL) {
            return primarySequenceURL
        }
        return standardizedInputURL
    }

    /// What the dialog hands the subcommand today for `inputURL`: the file
    /// named in the executed invocation, read before the staging folder is
    /// cleaned up.
    private func dialogResolution(of inputURL: URL) async throws -> (path: String, bytes: Data) {
        let runner = CapturingInputRunner()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: NoOutputImporter()
        )
        let workingDirectory = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        _ = try await service.execute(
            request: .derivative(request: .reverseComplement, inputURLs: [inputURL], outputMode: .perInput),
            workingDirectory: workingDirectory
        )
        return try XCTUnwrap(runner.captured, "the subcommand ran once")
    }

    private func requireReformat() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.reformat) else {
            try ToolAvailability.skipOrFail("managed reformat.sh is not installed")
        }
    }

    /// The record names in FASTQ text, in order.
    private func readNames(in bytes: Data) -> [String] {
        String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }

    /// Runs both resolutions and returns the dialog's, whose staging file is
    /// gone by the time `execute` returns, so its bytes are what is compared.
    @discardableResult
    private func assertParity(for inputURL: URL, shape: String, file: StaticString = #filePath, line: UInt = #line) async throws -> (path: String, bytes: Data) {
        let legacyDirectory = root.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = try await legacyResolution(of: inputURL, tempDirectory: legacyDirectory)
        let legacyBytes = try Data(contentsOf: legacyURL)

        let dialog = try await dialogResolution(of: inputURL)
        XCTAssertEqual(dialog.bytes, legacyBytes, "\(shape): the subcommand reads the same bytes", file: file, line: line)
        XCTAssertFalse(readNames(in: dialog.bytes).isEmpty, "\(shape): the resolved file holds reads", file: file, line: line)
        return dialog
    }

    func testASingleFileBundleResolvesToItsFileInPlaceEitherWay() async throws {
        let dialog = try await assertParity(for: shapes.single, shape: "single-file bundle")
        XCTAssertEqual(
            URL(fileURLWithPath: dialog.path).standardizedFileURL.path,
            shapes.single.appendingPathComponent("single.fastq").standardizedFileURL.path
        )
    }

    func testAMultiFileBundleResolvesToEveryFileJoinedInManifestOrderEitherWay() async throws {
        let dialog = try await assertParity(for: shapes.multiFile, shape: "multi-file bundle")
        XCTAssertEqual(readNames(in: dialog.bytes), ["m1", "m2", "m3", "m4", "m5"])
    }

    func testAFileInsideAMultiFileBundleResolvesToTheWholeBundleEitherWay() async throws {
        let dialog = try await assertParity(for: shapes.multiFileChunks[1], shape: "a chunk of a multi-file bundle")
        XCTAssertEqual(readNames(in: dialog.bytes), ["m1", "m2", "m3", "m4", "m5"])
    }

    func testAVirtualBundleResolvesToItsMaterializedReadsEitherWay() async throws {
        let dialog = try await assertParity(for: shapes.oriented, shape: "virtual orientMap bundle")
        XCTAssertEqual(readNames(in: dialog.bytes), ["s1", "s3"])
    }

    func testAnInterleavedBundleResolvesToItsFileInPlaceEitherWay() async throws {
        try await assertParity(for: shapes.interleaved, shape: "interleaved single-file bundle")
    }

    func testAFullPairedBundleResolvesToR1AndR2InterleavedEitherWay() async throws {
        try await requireReformat()
        let dialog = try await assertParity(for: shapes.paired, shape: "fullPaired bundle")
        XCTAssertEqual(readNames(in: dialog.bytes), ["p1/1", "p1/2", "p2/1", "p2/2"])
    }

    func testAFullMixedBundleResolvesToItsFilesJoinedEitherWay() async throws {
        try await requireReformat()
        try await assertParity(for: shapes.mixed, shape: "fullMixed bundle")
    }

    func testALooseFileResolvesToItselfEitherWay() async throws {
        let dialog = try await assertParity(for: shapes.looseFiles[1], shape: "loose file")
        XCTAssertEqual(URL(fileURLWithPath: dialog.path).standardizedFileURL.path, shapes.looseFiles[1].standardizedFileURL.path)
    }
}

/// Records the input file the one invocation names and its bytes, before the
/// service removes its staging folder.
private final class CapturingInputRunner: @unchecked Sendable, FASTQOperationCommandRunning {
    private let lock = NSLock()
    private var _captured: (path: String, bytes: Data)?

    var captured: (path: String, bytes: Data)? {
        lock.withLock { _captured }
    }

    private func record(_ invocation: FASTQCLIInvocation) throws {
        guard invocation.arguments.first == "reverse-complement", invocation.arguments.count > 1 else {
            throw CocoaError(.featureUnsupported)
        }
        let path = invocation.arguments[1]
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        lock.withLock { _captured = (path, bytes) }
    }

    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        try record(invocation)
        return FASTQCLIExecutionResult(outputURLs: [])
    }
}

private struct NoOutputImporter: FASTQOperationDirectImporting {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL,
        progress: FASTQOperationImportProgressHandler?
    ) async throws -> [URL] {
        []
    }
}
