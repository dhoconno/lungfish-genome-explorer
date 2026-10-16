// FASTQReferenceWrapperRouteReplayTests.swift - Where a FASTQ operation's FASTA output lands as a reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A FASTQ operation that writes a FASTA has it wrapped as a `.lungfishref` bundle in the
// operation's destination folder as given, which is the project, its Analyses folder, a folder
// the person chose or the input's folder, never the project's Reference Sequences folder
// (`MainSplitViewController+GenomicsDisplay.swift`, `runFASTQOperationLaunchRequestValidated`).
// The bundle's record then leads with the operation's own step. This class pins both on the
// route the wrapper runs, with the FASTA inside the project (ruling 5 of the A48 M3 review).

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQReferenceWrapperRouteReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        scratch = try TestTempDirectory.make(prefix: "fastq-reference-wrapper").resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testTheBundleLandsInTheFolderAsGivenAndLeadsWithTheOperationStep() async throws {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let source = project.appendingPathComponent("source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = try await Self.writeOperationOutput(in: analyses.appendingPathComponent("run-1", isDirectory: true))
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .rRNA, ensure: .rrna),
            inputURLs: [source],
            outputMode: .perInput
        )
        let importer = BundleFASTQOperationImporter(destinationDirectory: analyses, referenceBundleWrapper: try makeWrapper())

        let imported = try await importer.importOutputs(
            at: [output], forResolvedRequest: request, originalRequest: request, outputDirectory: output.deletingLastPathComponent()
        )

        XCTAssertEqual(imported.map(\.lastPathComponent), ["source-deacon-ribo-rrna.lungfishref"])
        let bundle = try XCTUnwrap(imported.first)
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL.path, analyses.standardizedFileURL.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: project.appendingPathComponent(ReferenceSequenceFolder.folderName).path),
            "the bundle goes to the folder as given, so no Reference Sequences folder is made"
        )
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        XCTAssertEqual(envelope.steps.first?.toolName, "fixture-tool", "the record leads with the operation's step")
        XCTAssertGreaterThan(envelope.steps.count, 1, "the import's own step follows the operation's")
        XCTAssertTrue(
            envelope.steps.contains { step in
                step.argv.contains("--bundle-dir") && step.argv.contains("--rehydrate-source-provenance")
            },
            "the import's step names the command that built and merged the record: \(envelope.steps.map(\.argv))"
        )
    }

    /// Plan decision C5 on the wrapper route, the twin of `ReferenceImportLeafExitReplayTests` (ruling A48 F2
    /// pin P7). The command merges the FASTA's record and publishes the bundle, so the bundle's file list and
    /// the digest of every file, its record included, read when the command returns equal those read when the
    /// importer returns.
    func testTheWrapperRouteWritesNoByteAfterTheCLIExits() async throws {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let source = project.appendingPathComponent("source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = try await Self.writeOperationOutput(in: analyses.appendingPathComponent("run-1", isDirectory: true))
        let request = FASTQOperationLaunchRequest.derivative(
            request: .ribosomalRNAFilter(retention: .rRNA, ensure: .rrna),
            inputURLs: [source],
            outputMode: .perInput
        )
        let wrapper = DigestingWrapper(inner: try makeWrapper())
        let importer = BundleFASTQOperationImporter(destinationDirectory: analyses, referenceBundleWrapper: wrapper)

        let imported = try await importer.importOutputs(
            at: [output], forResolvedRequest: request, originalRequest: request, outputDirectory: output.deletingLastPathComponent()
        )

        let bundle = try XCTUnwrap(imported.first)
        let atExit = try XCTUnwrap(wrapper.digestAtExit, "the importer ran the wrapper")
        XCTAssertNotNil(
            atExit["/" + ProvenanceWriter.provenanceFilename],
            "the command wrote the bundle's record before it exited: \(atExit.keys.sorted())"
        )
        XCTAssertEqual(try Self.digest(of: bundle), atExit, "the app wrote into the bundle after the command exited")
    }

    // MARK: - Cancel

    // The wrap has no Operations row, so the cancel of the FASTQ operation's task is its only Cancel.
    // It reaches the command through `CLIBundleBuildRunner.run(arguments:environmentAdditions:)`.

    func testATaskCancelledBeforeLaunchStopsTheWrapperAndMakesNoFolder() async throws {
        let source = scratch.appendingPathComponent("plain.fa")
        try ">chr1\nACGTACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let folder = scratch.appendingPathComponent("Analyses", isDirectory: true)
        let wrapper = try makeWrapper()
        let task = Task { () -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await wrapper.importReferenceBundle(sourceURL: source, outputDirectory: folder, preferredBundleName: "Cancelled")
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled task must not publish a bundle")
        } catch is CancellationError {
        } catch {
            XCTFail("a cancel is a CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a cancel before launch makes no folder")
    }

    func testCancellingTheTaskMidRunSendsSIGTERMAndEndsInsideTheGrace() async throws {
        let source = scratch.appendingPathComponent("plain.fa")
        try ">chr1\nACGTACGT\n".write(to: source, atomically: true, encoding: .utf8)
        let folder = scratch.appendingPathComponent("Analyses", isDirectory: true)
        // A stand-in lungfish-cli that turns SIGTERM into exit 125, as the real leaf does, and notes that it
        // runs. Its fifth word is the --bundle-dir folder of `import fasta <source> --bundle-dir <folder> ...`.
        // The loop ends by itself after a minute, so a run that nobody cancels fails the time check below.
        let stub = scratch.appendingPathComponent("lungfish-cli-stand-in")
        try """
        #!/bin/sh
        trap 'exit 125' TERM
        : > "$5.started"
        n=0
        while [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let started = URL(fileURLWithPath: folder.path + ".started")
        let wrapper = CLIReferenceBundleWrapper(cliURLOverride: stub)
        let task = Task {
            try await wrapper.importReferenceBundle(sourceURL: source, outputDirectory: folder, preferredBundleName: "Cancelled")
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: started.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "the stand-in command never ran")
        let cancelledAt = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return a bundle")
        } catch is CancellationError {
        } catch {
            XCTFail("a cancel is a CancellationError, got \(error)")
        }

        let elapsed = cancelledAt.duration(to: clock.now)
        XCTAssertLessThan(
            elapsed, CLIBundleBuildRunner.terminationGracePeriod + .seconds(2),
            "SIGTERM ends the command inside the grace the runner gives it before SIGKILL"
        )
        let built = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".lungfishref") }
        XCTAssertEqual(built, [], "a cancelled wrap publishes no bundle")
    }

    /// The wrapper the importer runs by default, on the `lungfish-cli` beside the test bundle. Until
    /// A48 M4 this was the helper's in-process body, the service called with the folder as given.
    private func makeWrapper() throws -> any ReferenceBundleWrapping {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        return CLIReferenceBundleWrapper(cliURLOverride: cli)
    }

    /// The wrapper the importer runs, with the bundle's digest read the moment the command returns.
    private final class DigestingWrapper: ReferenceBundleWrapping, @unchecked Sendable {
        private let inner: any ReferenceBundleWrapping
        private let lock = NSLock()
        private var stored: [String: String]?

        init(inner: any ReferenceBundleWrapping) {
            self.inner = inner
        }

        /// The digest of the bundle at the moment the wrapped command returned, nil before it ran.
        var digestAtExit: [String: String]? {
            lock.withLock { stored }
        }

        func importReferenceBundle(
            sourceURL: URL,
            outputDirectory: URL,
            preferredBundleName: String?
        ) async throws -> URL {
            let bundle = try await inner.importReferenceBundle(
                sourceURL: sourceURL, outputDirectory: outputDirectory, preferredBundleName: preferredBundleName
            )
            let digest = try FASTQReferenceWrapperRouteReplayTests.digest(of: bundle)
            lock.withLock { stored = digest }
            return bundle
        }
    }

    /// The SHA-256 of every regular file under `bundle`, by its path inside the bundle with a leading slash.
    /// The keys come from `subpathsOfDirectory`, not from the enumerator's URLs, because
    /// `resolvingSymlinksInPath` drops a leading `/private` that the enumerator's URLs keep.
    private static func digest(of bundle: URL) throws -> [String: String] {
        let root = bundle.resolvingSymlinksInPath()
        var result: [String: String] = [:]
        for subpath in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(subpath)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result["/" + subpath] = try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }

    // MARK: - Fixture

    /// A FASTQ operation's output with its record, normalized to FASTA as the operation leaves it,
    /// as `ReferenceImportParityReplayTests` builds it. Returns the FASTA.
    private static func writeOperationOutput(in folder: URL) async throws -> URL {
        let execution = folder.appendingPathComponent("execution", isDirectory: true)
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
        let reads = folder.appendingPathComponent("reads.fastq")
        let raw = execution.appendingPathComponent("output.fastq")
        try Data("@r\nACGTACGTAC\n+\nIIIIIIIIII\n".utf8).write(to: reads)
        try Data("@r\nACGTACGTAC\n+\nIIIIIIIIII\n".utf8).write(to: raw)
        let argv = ["fixture-tool", "--input", reads.path, "--output", raw.path]
        let step = ProvenanceStep(
            toolName: "fixture-tool", toolVersion: "1", argv: argv, runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [try descriptor(reads, role: .input)], outputs: [try descriptor(raw, role: .output)],
            exitStatus: 0, wallTimeSeconds: 1
        )
        let run = try ProvenanceRunBuilder(
            workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture-tool", toolVersion: "1"
        )
        .argv(argv).runtime(ProvenanceRuntimeIdentity()).input(reads, format: .fastq)
        .output(raw, format: .fastq).step(step)
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(run, toSidecar: ProvenanceRecorder.fileSidecarURL(for: raw))
        _ = try await SequenceProcessingOutputNormalizer.normalize(outputURL: raw, preferredFormat: .fasta)
        let normalized = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: execution.path).first { $0.hasPrefix("sequence-normalized-") }
        )
        return execution.appendingPathComponent(normalized, isDirectory: true).appendingPathComponent("output.fasta")
    }

    private static func descriptor(_ url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), role: role
        )
    }
}
