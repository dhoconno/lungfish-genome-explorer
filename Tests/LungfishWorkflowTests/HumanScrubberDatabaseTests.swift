// HumanScrubberDatabaseTests.swift - Tests for human scrubber database handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport
import CryptoKit

final class HumanScrubberDatabaseTests: XCTestCase {

    private var tempDir: URL!
    /// A private suite per test: DatabaseRegistry writes its override keys
    /// here instead of the process-shared preferences, which parallel xctest
    /// workers see through cfprefsd.
    private var preferencesSuite: TestDefaultsSuite!
    private var preferences: UserDefaults { preferencesSuite.defaults }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("human-scrubber-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        preferencesSuite = makeTestDefaultsSuite(prefix: "HumanScrubberDatabaseTests")
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testManagedDatabaseProvenanceRefusesUnmeasuredRuntime() throws {
        let result = ManagedDatabaseToolResult(stdout: "ok", stderr: "", exitCode: 0, wallTime: 0.1)
        XCTAssertThrowsError(try result.provenanceStep(arguments: ["fixture"], durableArguments: ["fixture"],
            inputs: [], outputs: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("runtime provenance is unavailable"))
        }
    }

    func testManagedDatabaseVersionProbeUsesObservedValueAndRejectsUnknown() throws {
        XCTAssertEqual(try DatabaseRegistry.observedManagedToolVersion(name: "deacon",
            stdout: "deacon 9.8.7-fixture\n", stderr: "", exitCode: 0), "9.8.7-fixture")
        XCTAssertEqual(try DatabaseRegistry.observedManagedToolVersion(name: "deacon",
            stdout: "", stderr: "deacon version 0.16.2\n", exitCode: 0), "0.16.2")
        for output in ["", "unknown", "another-tool 0.16.0", "deacon 0.16.0\ndeacon 0.17.0"] {
            XCTAssertThrowsError(try DatabaseRegistry.observedManagedToolVersion(name: "deacon",
                stdout: output, stderr: "", exitCode: 0))
        }
        XCTAssertThrowsError(try DatabaseRegistry.observedManagedToolVersion(name: "deacon",
            stdout: "deacon 0.16.0", stderr: "", exitCode: 1))
    }

    func testManagedDatabaseInstallerClassifiesURLSessionCancellation() {
        XCTAssertTrue(DatabaseRegistry.isCancellation(CancellationError()))
        XCTAssertTrue(DatabaseRegistry.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(DatabaseRegistry.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(DatabaseRegistry.isCancellation(NSError(domain: "LungfishTests", code: NSURLErrorCancelled)))
    }

    func testHumanScrubberInstallerUsesPinnedManifestFilenameAndMd5URL() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )
        guard let manifest = await registry.manifest(for: "human-scrubber") else {
            XCTFail("Expected human-scrubber manifest")
            return
        }
        guard let artifactURLs = await registry.managedDatabaseArtifactURLs(for: manifest) else {
            XCTFail("Expected managed database URLs")
            return
        }

        XCTAssertEqual(artifactURLs.databaseURL.lastPathComponent, "human_filter.db.20260706v2")
        XCTAssertEqual(artifactURLs.databaseURL.absoluteString, "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20260706v2")
        XCTAssertEqual(artifactURLs.md5URL.lastPathComponent, "human_filter.db.20260706v2.md5")
        XCTAssertEqual(artifactURLs.md5URL.absoluteString, "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20260706v2.md5")
    }

    func testRequiredDatabasePathThrowsInstallRequiredWhenHumanScrubberDatabaseMissing() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "human-scrubber")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "human-scrubber")
            XCTAssertEqual(displayName, "Human Read Scrubber Database")
        }
    }

    func testRequiredDatabasePathMapsLegacyHumanScrubberIDToCanonicalManifest() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "sra-human-scrubber")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "human-scrubber")
            XCTAssertEqual(displayName, "Human Read Scrubber Database")
        }
    }

    func testRequiredDatabasePathMapsDeaconAliasToCanonicalManifest() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )

        do {
            _ = try await registry.requiredDatabasePath(for: "deacon")
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
        }
    }

    func testFASTQBatchImporterCanonicalizesLegacyHumanScrubberAliasToDeaconManagedDatabase() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )

        do {
            _ = try await FASTQBatchImporter.resolveHumanScrubberDatabasePath(
                databaseID: "sra-human-scrubber",
                registry: registry
            )
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
        }
    }

    func testFASTQBatchImporterReportsInstallRequiredWhenHumanScrubberDatabaseMissing() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases"),
            preferences: preferencesSuite.makeDefaults()
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("project"), platform: .illumina,
            recipe: ProcessingRecipe(
                name: "Human Scrub Only",
                steps: [
                    FASTQDerivativeOperation(
                        kind: .humanReadScrub,
                        createdAt: .distantPast,
                        humanScrubRemoveReads: true,
                        humanScrubDatabaseID: "human-scrubber"
                    )
                ]
            ),
            threads: 1
        )
        let pair = SamplePair(
            sampleName: "sample",
            r1: tempDir.appendingPathComponent("input_R1.fastq"),
            r2: tempDir.appendingPathComponent("input_R2.fastq")
        )
        try makeFASTQFile(at: pair.r1)
        try makeFASTQFile(at: try XCTUnwrap(pair.r2))

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            databaseRegistry: registry
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.errors.first?.error.contains("required before running human-read scrubbing") == true)
    }

    func testHumanScrubberInstallWritesManagedDatabaseProvenance() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8)
                : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader,
            preferences: preferencesSuite.makeDefaults()
        )

        let installed = try await registry.installManagedDatabase("human-scrubber", reinstall: true)

        XCTAssertEqual(try Data(contentsOf: installed), payload)
        let provenanceURL = installed.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let run = try decodeWorkflowRun(at: provenanceURL)
        XCTAssertEqual(run.name, "Human Read Scrubber Database managed database install")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["workflow"]?.stringValue, "managed-database-install")
        XCTAssertEqual(run.parameters["databaseID"]?.stringValue, "human-scrubber")
        XCTAssertEqual(run.parameters["expectedMD5"]?.stringValue, expectedMD5)
        XCTAssertEqual(run.parameters["actualMD5"]?.stringValue, expectedMD5)
        XCTAssertEqual(run.steps.map(\.toolName), ["URLSession", "URLSession", "CryptoKit"])
        XCTAssertEqual(run.steps.first?.outputs.first?.path, installed.path)
        XCTAssertEqual(run.steps.first?.outputs.first?.sizeBytes, UInt64(payload.count))
        // Read the same preferences store DatabaseRegistry writes to (the
        // injected per-test suite).
        XCTAssertEqual(
            preferences.string(forKey: "database.human-scrubber.overrideFilename"),
            installed.lastPathComponent
        )
    }

    func testManagedDatabaseInstallWritesCanonicalProvenanceEnvelope() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8)
                : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader,
            preferences: preferencesSuite.makeDefaults()
        )

        let installed = try await registry.installManagedDatabase("human-scrubber", reinstall: true)

        let provenanceURL = installed.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(envelope.workflowName, "Human Read Scrubber Database managed database install")
        XCTAssertEqual(envelope.toolName, "URLSession")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.options.explicit["databaseID"]?.stringValue, "human-scrubber")
        XCTAssertEqual(envelope.options.explicit["expectedMD5"]?.stringValue, expectedMD5)
        XCTAssertEqual(envelope.output?.path, installed.path)
        XCTAssertEqual(envelope.output?.fileSize, UInt64(payload.count))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.status, .completed)
    }

    func testDeaconPanhumanInstallWritesManagedDatabaseProvenance() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let indexPayload = Data("deacon-index\n".utf8)
        let toolRunner: ManagedDatabaseToolRunner = { name, arguments, environment, _, stderrHandler in
            if arguments.starts(with: ["index", "fetch"]), let outputPath = arguments.last {
                try indexPayload.write(to: URL(fileURLWithPath: outputPath))
                stderrHandler?("Fetching panhuman")
            }
            return ManagedDatabaseToolResult(
                stdout: "ok",
                stderr: "",
                exitCode: 0,
                wallTime: 0.25,
                toolVersion: "9.8.7-fixture",
                command: ["/fixture/runtime/bin/micromamba", "run", "-n", environment, name] + arguments,
                runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "/fixture/runtime/envs/deacon/bin/deacon",
                    condaEnvironment: environment, condaPrefix: "/fixture/runtime/envs/deacon"),
                resolvedOptions: ["MAMBA_ROOT_PREFIX": .string("/fixture/runtime")]
            )
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseToolRunner: toolRunner,
            // The bundled lock pins the real index, so the fixture's own digest and size are pinned in its place.
            managedDatabaseLockLookup: try lockLookup(pinning: indexPayload, as: "deacon-panhuman"),
            preferences: preferencesSuite.makeDefaults()
        )

        let installed = try await registry.installManagedDatabase("deacon-panhuman", reinstall: true)

        XCTAssertEqual(try Data(contentsOf: installed), indexPayload)
        let provenanceURL = installed.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let run = try decodeWorkflowRun(at: provenanceURL)
        XCTAssertEqual(run.name, "Human Read Removal Data managed database install")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["databaseID"]?.stringValue, "deacon-panhuman")
        XCTAssertEqual(run.parameters["condaEnvironment"]?.stringValue, "deacon")
        XCTAssertEqual(run.steps.map(\.toolName), ["deacon", "deacon"])
        XCTAssertFalse(run.steps.contains { $0.toolVersion == "0.15.0" }, "An unmeasured legacy version must never be emitted as actual runtime evidence")
        XCTAssertTrue(run.steps.allSatisfy { $0.command.first?.hasPrefix("/") == true }, "Provenance must identify the resolved runtime executable")
        XCTAssertEqual(run.steps.map(\.toolVersion), ["9.8.7-fixture", "9.8.7-fixture"])
        XCTAssertEqual(run.steps.first?.runtimeIdentity?.condaPrefix, "/fixture/runtime/envs/deacon")
        XCTAssertEqual(run.steps.first?.runtimeIdentity?.executablePath, "/fixture/runtime/envs/deacon/bin/deacon")
        XCTAssertEqual(run.steps.first?.resolvedOptions?["MAMBA_ROOT_PREFIX"]?.stringValue, "/fixture/runtime")
        XCTAssertEqual(Array(run.steps.first!.durableReplayArgv!.prefix(3)),
            ["/usr/bin/env", "MAMBA_ROOT_PREFIX=/fixture/runtime", "/fixture/runtime/bin/micromamba"])
        let canonical = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: provenanceURL))
        XCTAssertEqual(canonical.steps.first?.toolVersion, "9.8.7-fixture")
        XCTAssertEqual(canonical.steps.first?.runtimeIdentity?.condaPrefix, "/fixture/runtime/envs/deacon")
        XCTAssertEqual(run.steps.first?.outputs.first?.path, installed.path)
        XCTAssertEqual(run.steps.first?.durableReplayArgv?.suffix(2), ["-o", installed.path])
        XCTAssertEqual(run.steps.first?.outputs.first?.sizeBytes, UInt64(indexPayload.count))
    }

    /// The bundled lock pins the real panhuman index, so an install whose fetched file is not that file is refused
    /// with the install error, and it leaves no index, partial file or record behind.
    func testDeaconPanhumanInstallRefusesAFetchedIndexThatTheBundledLockDoesNotPin() async throws {
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let indexPayload = Data("deacon-index\n".utf8)
        let toolRunner: ManagedDatabaseToolRunner = { _, arguments, _, _, _ in
            if arguments.starts(with: ["index", "fetch"]), let outputPath = arguments.last {
                try indexPayload.write(to: URL(fileURLWithPath: outputPath))
            }
            return ManagedDatabaseToolResult(stdout: "ok", stderr: "", exitCode: 0, wallTime: 0.25)
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try bundledDatabasesRoot(),
            userDatabasesRoot: userRoot,
            managedDatabaseToolRunner: toolRunner,
            preferences: preferencesSuite.makeDefaults()
        )
        let pinnedSize = try XCTUnwrap(ManagedToolLock.bundled.database(id: "deacon-panhuman")?.sizeBytes)

        do {
            _ = try await registry.installManagedDatabase("deacon-panhuman", reinstall: true)
            XCTFail("The install accepted an index the bundled lock does not pin")
        } catch HumanScrubberDatabaseError.installationFailed(let databaseID, let displayName, let reason) {
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
            XCTAssertEqual(reason, "The index is \(indexPayload.count) bytes, and the bundled lock pins \(pinnedSize) bytes.")
        }
        XCTAssertEqual(regularFileNames(under: userRoot), [], "A refused install must leave no index, partial file or record")
    }

    /// A lock lookup with one entry, which pins `payload`'s SHA-256 and size under `id`. The bundled lock pins the
    /// real index, so an install of a small fixture takes this in its place and still runs the lock check.
    private func lockLookup(pinning payload: Data, as id: String) throws -> ManagedDatabaseLockLookup {
        let json: [String: Any] = [
            "id": id, "tool": "deacon", "displayName": id, "version": "fixture-1", "filename": "fixture.idx",
            "indexFormat": 3, "sizeBytes": payload.count,
            "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
        ]
        let spec = try JSONDecoder().decode(DatabaseSpec.self, from: JSONSerialization.data(withJSONObject: json))
        return { $0 == id ? spec : nil }
    }

    private func regularFileNames(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var names: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(url.lastPathComponent)
            }
        }
        return names.sorted()
    }

    func testManagedDatabaseInstallRemovesFinalPayloadWhenProvenanceWriteFails() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8)
                : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let provenanceWriter: ManagedDatabaseProvenanceWriter = { _, _ in
            throw TestProvenanceError.forcedFailure
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader,
            managedDatabaseProvenanceWriter: provenanceWriter,
            preferences: preferencesSuite.makeDefaults()
        )

        do {
            _ = try await registry.installManagedDatabase("human-scrubber", reinstall: true)
            XCTFail("Expected provenance write failure to fail the install")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installationFailed(let databaseID, _, let reason) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "human-scrubber")
            XCTAssertTrue(reason.contains("managed database install provenance"))
            XCTAssertTrue(reason.contains("forcedFailure"))
        }

        let installDirectory = userRoot.appendingPathComponent("human-scrubber", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installDirectory.appendingPathComponent("human_filter.db.20260706v2").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
            )
        )
        XCTAssertNil(preferences.string(forKey: "database.human-scrubber.overrideFilename"))
    }

    private func makeFASTQFile(at url: URL) throws {
        let content = """
        @read1
        ACGTACGTACGT
        +
        IIIIIIIIIIII
        @read2
        TGCATGCATGCA
        +
        IIIIIIIIIIII
        """
        try content.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Root for bundled-payload lookups only. Manifest metadata (filename, version,
    /// description, etc.) now comes from `ManagedToolLock.bundled` regardless of this
    /// directory's contents, so this just needs to exist for `databasesRoot()`.
    private func bundledDatabasesRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("bundled-databases", isDirectory: true)
        for databaseID in ["human-scrubber", "deacon-panhuman", "deacon-ribokmers"] {
            let databaseDir = root.appendingPathComponent(databaseID, isDirectory: true)
            try FileManager.default.createDirectory(at: databaseDir, withIntermediateDirectories: true)
        }
        return root
    }

    private func decodeWorkflowRun(at url: URL) throws -> WorkflowRun {
        return try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: url)).legacyWorkflowRun()
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum TestProvenanceError: Error {
        case forcedFailure
    }
}
