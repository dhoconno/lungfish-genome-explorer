// HumanScrubberDatabaseTests.swift - Tests for human scrubber database handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import CryptoKit

final class HumanScrubberDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var savedOverrides: [String: String] = [:]
    private let managedDatabaseOverrideKeys = [
        "database.human-scrubber.overrideFilename",
        "database.deacon-panhuman.overrideFilename",
        "database.deacon-ribokmers.overrideFilename",
    ]

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("human-scrubber-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedOverrides = Dictionary(uniqueKeysWithValues: managedDatabaseOverrideKeys.compactMap { key in
            UserDefaults.standard.string(forKey: key).map { (key, $0) }
        })
        clearManagedDatabaseOverrideDefaults()
    }

    override func tearDown() async throws {
        clearManagedDatabaseOverrideDefaults()
        for (key, value) in savedOverrides { UserDefaults.standard.set(value, forKey: key) }
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
            userDatabasesRoot: tempDir.appendingPathComponent("user-databases")
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
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
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
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
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
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
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
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
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
            userDatabasesRoot: tempDir.appendingPathComponent("empty-user-databases")
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("project"),
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
            managedDatabaseDownloader: downloader
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
        XCTAssertEqual(UserDefaults.standard.string(forKey: "database.human-scrubber.overrideFilename"), installed.lastPathComponent)
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
            managedDatabaseDownloader: downloader
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
        XCTAssertEqual(envelope.legacyRun?.parameters["databaseID"]?.stringValue, "human-scrubber")
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
            managedDatabaseToolRunner: toolRunner
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

    func testDeaconRibokmersInstallWritesDurableReplayProvenance() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let referencePayload = Data(">ribo\nACGT\n".utf8)
        let indexPayload = Data("ribokmers-index\n".utf8)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try referencePayload.write(to: outputURL)
            progress(1.0, Int64(referencePayload.count), Int64(referencePayload.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let toolRunner: ManagedDatabaseToolRunner = { name, arguments, environment, _, _ in
            if arguments.starts(with: ["index", "build"]),
               let outputFlagIndex = arguments.firstIndex(of: "-o"),
               arguments.indices.contains(outputFlagIndex + 1) {
                try indexPayload.write(to: URL(fileURLWithPath: arguments[outputFlagIndex + 1]))
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
            managedDatabaseDownloader: downloader,
            managedDatabaseToolRunner: toolRunner
        )

        let installed = try await registry.installManagedDatabase("deacon-ribokmers", reinstall: true)

        XCTAssertEqual(try Data(contentsOf: installed), indexPayload)
        let provenanceURL = installed.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let run = try decodeWorkflowRun(at: provenanceURL)
        XCTAssertEqual(run.name, "Ribosomal RNA Removal Data managed database install")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["databaseID"]?.stringValue, "deacon-ribokmers")
        XCTAssertEqual(run.steps.map(\.toolName), ["URLSession", "deacon", "deacon"])
        let buildStep = try XCTUnwrap(run.steps.first { $0.command.contains("build") })
        XCTAssertEqual(buildStep.outputs.first?.path, installed.path)
        XCTAssertEqual(buildStep.durableReplayArgv?.contains(installed.path), true)
        XCTAssertEqual(buildStep.durableReplayArgv?.contains { $0.hasSuffix(".partial") }, false)
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
            managedDatabaseProvenanceWriter: provenanceWriter
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
        XCTAssertNil(UserDefaults.standard.string(forKey: "database.human-scrubber.overrideFilename"))
    }

    func testRibokmersInstallRemovesReferenceAndIndexWhenProvenanceWriteFails() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let referencePayload = Data(">ribo\nACGT\n".utf8)
        let indexPayload = Data("ribokmers-index\n".utf8)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try referencePayload.write(to: outputURL)
            progress(1.0, Int64(referencePayload.count), Int64(referencePayload.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let toolRunner: ManagedDatabaseToolRunner = { name, arguments, environment, _, _ in
            if arguments.starts(with: ["index", "build"]),
               let outputFlagIndex = arguments.firstIndex(of: "-o"),
               arguments.indices.contains(outputFlagIndex + 1) {
                try indexPayload.write(to: URL(fileURLWithPath: arguments[outputFlagIndex + 1]))
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
        let provenanceWriter: ManagedDatabaseProvenanceWriter = { _, _ in
            throw TestProvenanceError.forcedFailure
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader,
            managedDatabaseToolRunner: toolRunner,
            managedDatabaseProvenanceWriter: provenanceWriter
        )

        do {
            _ = try await registry.installManagedDatabase("deacon-ribokmers", reinstall: true)
            XCTFail("Expected provenance write failure to fail the install")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installationFailed(let databaseID, _, let reason) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-ribokmers")
            XCTAssertTrue(reason.contains("managed database install provenance"))
        }

        let installDirectory = userRoot.appendingPathComponent("deacon-ribokmers", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installDirectory.appendingPathComponent("ribokmers.k31w15.idx").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installDirectory.appendingPathComponent("ribokmers.fa.gz").path
            )
        )
        XCTAssertNil(UserDefaults.standard.string(forKey: "database.deacon-ribokmers.overrideFilename"))
        let resolvedPath = await registry.effectiveDatabasePath(for: "deacon-ribokmers")
        XCTAssertNil(resolvedPath)
    }

    func testRibokmersInstallRemovesReferenceWhenCancelledAfterDownload() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let referencePayload = Data(">ribo\nACGT\n".utf8)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try referencePayload.write(to: outputURL)
            progress(1.0, Int64(referencePayload.count), Int64(referencePayload.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.125)
        }
        let toolRunner: ManagedDatabaseToolRunner = { _, _, _, _, _ in
            throw CancellationError()
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader,
            managedDatabaseToolRunner: toolRunner
        )

        do {
            _ = try await registry.installManagedDatabase("deacon-ribokmers", reinstall: true)
            XCTFail("Expected cancellation to fail the install")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installationCancelled(let databaseID, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-ribokmers")
        }

        let installDirectory = userRoot.appendingPathComponent("deacon-ribokmers", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installDirectory.appendingPathComponent("ribokmers.fa.gz").path
            )
        )
        XCTAssertNil(UserDefaults.standard.string(forKey: "database.deacon-ribokmers.overrideFilename"))
        let resolvedPath = await registry.effectiveDatabasePath(for: "deacon-ribokmers")
        XCTAssertNil(resolvedPath)
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowRun.self, from: Data(contentsOf: url))
    }

    private func clearManagedDatabaseOverrideDefaults() {
        for key in managedDatabaseOverrideKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum TestProvenanceError: Error {
        case forcedFailure
    }
}
