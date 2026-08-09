// AssemblyBatchOutputLayoutTests.swift - Coverage for assembly fan-out batch
// directory grouping (BG4, batch-results-grouping campaign).
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class AssemblyBatchOutputLayoutTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-assembly-batch-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Bundle fixtures

    /// Builds a real `.lungfishfastq` bundle backed by a `source-files.json`
    /// multi-file manifest listing two physical FASTQ files named with the
    /// R1/R2 convention -- the on-disk shape of a genuine paired-end sample
    /// imported as one bundle.
    private func makeGenuinePairedBundle(named bundleName: String, in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let r1Name = "\(bundleName)_R1.fastq"
        let r2Name = "\(bundleName)_R2.fastq"
        let r1URL = bundleURL.appendingPathComponent(r1Name)
        let r2URL = bundleURL.appendingPathComponent(r2Name)
        let r1Data = "@r1\nACGT\n+\nIIII\n"
        let r2Data = "@r2\nTGCA\n+\nIIII\n"
        try r1Data.write(to: r1URL, atomically: true, encoding: .utf8)
        try r2Data.write(to: r2URL, atomically: true, encoding: .utf8)

        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: r1Name, originalPath: r1URL.path, sizeBytes: Int64(r1Data.utf8.count), isSymlink: false),
            .init(filename: r2Name, originalPath: r2URL.path, sizeBytes: Int64(r2Data.utf8.count), isSymlink: false),
        ])
        try manifest.save(to: bundleURL)

        return bundleURL
    }

    private func makePooledAssembleRequest(
        inputURLs: [URL],
        outputDirectory: URL,
        projectName: String = "pooled-run"
    ) -> FASTQOperationLaunchRequest {
        .assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: inputURLs,
                projectName: projectName,
                outputDirectory: outputDirectory,
                pairedEnd: false,
                threads: 4
            ),
            outputMode: .perInput
        )
    }

    private func outputDirectory(of request: FASTQOperationLaunchRequest) -> URL? {
        guard case .assemble(let assemblyRequest, _) = request else { return nil }
        return assemblyRequest.outputDirectory
    }

    private func projectName(of request: FASTQOperationLaunchRequest) -> String? {
        guard case .assemble(let assemblyRequest, _) = request else { return nil }
        return assemblyRequest.projectName
    }

    // MARK: - N > 1: grouped batch layout

    func testTwoBundlesYieldOneBatchDirectoryWithTwoBundleNamedChildrenAndNoSiblings() throws {
        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 2)
        let childDirs = children.compactMap(outputDirectory(of:))
        XCTAssertEqual(childDirs.count, 2)

        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: analysesDir, includingPropertiesForKeys: nil)
        // Exactly one entry at the Analyses root: the batch directory. No
        // sibling `spades-<ts>` single-run directories.
        XCTAssertEqual(entries.count, 1)
        let batchDir = try XCTUnwrap(entries.first)
        XCTAssertTrue(batchDir.lastPathComponent.hasPrefix("spades-batch-"))

        XCTAssertEqual(childDirs[0].lastPathComponent, "SampleA")
        XCTAssertEqual(childDirs[1].lastPathComponent, "SampleB")
        XCTAssertEqual(childDirs[0].deletingLastPathComponent().standardizedFileURL, batchDir.standardizedFileURL)
        XCTAssertEqual(childDirs[1].deletingLastPathComponent().standardizedFileURL, batchDir.standardizedFileURL)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: childDirs[0].path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: childDirs[1].path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - N == 1: unchanged flat layout (regression pin)

    func testSingleBundleLeavesOutputDirectoryUnsetAndCreatesNoBatchDirectory() throws {
        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 1)
        // Single-bundle path returns `self` unchanged -- no batch directory
        // (nor anything else) should have been created as a side effect.
        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysesDir.path))
        XCTAssertEqual(outputDirectory(of: children[0]), tempDir)
    }

    func testNilProjectURLLeavesChildOutputDirectoriesUnsetAndCreatesNoBatchDirectory() throws {
        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        // projectURL omitted (defaults to nil): caller's per-child
        // createAnalysisDirectory fallback must keep working exactly as
        // before this change.
        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true)
        )

        XCTAssertEqual(children.count, 2)
        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysesDir.path))
        // Children keep the pooled request's placeholder output directory
        // (the pre-BG4 `.replacingInputURLs`/`.replacingPairedEnd`/
        // `.replacingProjectName` chain never touches `outputDirectory`).
        XCTAssertEqual(outputDirectory(of: children[0]), tempDir)
        XCTAssertEqual(outputDirectory(of: children[1]), tempDir)
    }

    // MARK: - Ordering invariant (spec §3): folder suffixes agree with projectName suffixes

    /// Two bundles that sanitize to the same display name must dedup BOTH
    /// their batch sample directory name AND their `projectName` with the
    /// identical numeric suffix, in the same fixed input order -- proving
    /// the two dedup passes (AnalysesFolder's directory dedup and
    /// `uniqueAssemblyProjectName`) agree because both walk
    /// `batchRequest.inputURLs` in the same order.
    func testDuplicateBundleNamesProduceAgreeingFolderSuffixesAndProjectNameSuffixes() throws {
        let subdirA = tempDir.appendingPathComponent("groupA", isDirectory: true)
        let subdirB = tempDir.appendingPathComponent("groupB", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirB, withIntermediateDirectories: true)
        let bundleA = try makeGenuinePairedBundle(named: "sample", in: subdirA)
        let bundleB = try makeGenuinePairedBundle(named: "sample", in: subdirB)

        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 2)
        let childDirs = children.compactMap(outputDirectory(of:))
        let childProjectNames = children.compactMap(projectName(of:))

        XCTAssertEqual(childDirs.map(\.lastPathComponent), ["sample", "sample-2"])
        XCTAssertEqual(childProjectNames, ["sample", "sample-2"])
    }

    func testThreeIdenticallyNamedBundlesDedupFolderAndProjectNameSuffixesInLockstep() throws {
        var bundles: [URL] = []
        for index in 0..<3 {
            let subdir = tempDir.appendingPathComponent("group\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            bundles.append(try makeGenuinePairedBundle(named: "dup", in: subdir))
        }

        let pooledRequest = makePooledAssembleRequest(inputURLs: bundles, outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 3)
        let childDirs = children.compactMap(outputDirectory(of:))
        let childProjectNames = children.compactMap(projectName(of:))

        XCTAssertEqual(childDirs.map(\.lastPathComponent), ["dup", "dup-2", "dup-3"])
        XCTAssertEqual(childProjectNames, ["dup", "dup-2", "dup-3"])
    }

    // MARK: - Empty-batch cleanup (spec §6), via the shared hoisted helper

    func testSharedCleanupRemovesAssemblyBatchDirectoryWhenAllPrecreatedSampleDirsAreStillEmpty() throws {
        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )
        let childDirs = children.compactMap(outputDirectory(of:))
        let batchDir = try XCTUnwrap(childDirs.first).deletingLastPathComponent()

        // Simulates every child failing before it wrote any output.
        AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: batchDir.path))
    }

    func testSharedCleanupKeepsAssemblyBatchDirectoryWhenOneSampleDirHasPartialOutput() throws {
        let bundleA = try makeGenuinePairedBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeGenuinePairedBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledAssembleRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentAssembleLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )
        let childDirs = children.compactMap(outputDirectory(of:))
        let batchDir = try XCTUnwrap(childDirs.first).deletingLastPathComponent()

        try Data("partial-contigs".utf8).write(to: childDirs[1].appendingPathComponent("contigs.fasta"))

        AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childDirs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childDirs[1].appendingPathComponent("contigs.fasta").path))
    }
}
