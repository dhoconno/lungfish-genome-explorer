import XCTest
@testable import LungfishWorkflow

final class PluginPackStatusServiceTests: XCTestCase {
    func testStatusForVisiblePackDoesNotEvaluateUnrelatedVisiblePackRequirements() async throws {
        actor DatabaseRecorder {
            var callCount = 0

            func recordCall() {
                callCount += 1
            }

            func recordedCallCount() -> Int { callCount }
        }

        let recorder = DatabaseRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await recorder.recordCall()
                return false
            },
            cacheLifetime: 60
        )

        _ = await service.status(forPackID: "assembly")

        let callCount = await recorder.recordedCallCount()
        XCTAssertEqual(callCount, 0)
    }

    func testStatusForPackReusesPerPackCachedResultWithinTTL() async throws {
        actor DatabaseRecorder {
            var callCount = 0

            func recordCall() {
                callCount += 1
            }

            func recordedCallCount() -> Int { callCount }
        }

        let recorder = DatabaseRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await recorder.recordCall()
                return false
            },
            cacheLifetime: 60
        )

        _ = await service.status(for: .requiredSetupPack)
        _ = await service.status(for: .requiredSetupPack)

        let callCount = await recorder.recordedCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testVisibleStatusesReuseCachedResultWithinTTL() async throws {
        final class DatabaseGate: @unchecked Sendable {
            var callCount = 0
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?

            func waitForRelease() async {
                lock.withLock {
                    callCount += 1
                }
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        self.continuation = continuation
                    }
                }
            }

            func release() {
                let continuation = lock.withLock {
                    let continuation = self.continuation
                    self.continuation = nil
                    return continuation
                }
                continuation?.resume()
            }

            func recordedCallCount() -> Int { lock.withLock { callCount } }
        }

        let gate = DatabaseGate()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await gate.waitForRelease()
                return false
            },
            cacheLifetime: 60
        )

        async let firstStatuses = service.visibleStatuses()

        try? await Task.sleep(for: .milliseconds(50))
        let initialCallCount = gate.recordedCallCount()
        XCTAssertEqual(initialCallCount, 1)

        gate.release()
        _ = await firstStatuses
        _ = await service.visibleStatuses()

        let finalCallCount = gate.recordedCallCount()
        XCTAssertEqual(finalCallCount, 1)
    }

    func testVisibleStatusesUsePersistedSnapshotAcrossServiceInstancesWithinTTL() async throws {
        actor DatabaseRecorder {
            var callCount = 0

            func recordCall() {
                callCount += 1
            }

            func recordedCallCount() -> Int { callCount }
        }

        let rootPrefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CondaManager(
            rootPrefix: rootPrefix,
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let recorder = DatabaseRecorder()
        let firstService = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await recorder.recordCall()
                return false
            },
            cacheLifetime: 60
        )

        _ = await firstService.visibleStatuses()

        let secondService = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                try? await Task.sleep(for: .milliseconds(500))
                return false
            },
            cacheLifetime: 60
        )

        let started = Date()
        _ = await secondService.visibleStatuses()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.2)
        let callCount = await recorder.recordedCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testVisibleStatusesAreInvalidatedAfterExplicitCacheClear() async throws {
        actor DatabaseRecorder {
            var callCount = 0

            func recordCall() {
                callCount += 1
            }

            func recordedCallCount() -> Int { callCount }
        }

        let recorder = DatabaseRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await recorder.recordCall()
                return false
            },
            cacheLifetime: 60
        )

        _ = await service.visibleStatuses()
        _ = await service.visibleStatuses()
        await service.invalidateVisibleStatusesCache()
        _ = await service.visibleStatuses()

        let callCount = await recorder.recordedCallCount()
        XCTAssertEqual(callCount, 2)
    }

    func testVisibleStatusesShareInFlightRefreshWork() async throws {
        final class DatabaseGate: @unchecked Sendable {
            var callCount = 0
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?

            func waitForRelease() async {
                lock.withLock {
                    callCount += 1
                }
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        self.continuation = continuation
                    }
                }
            }

            func release() {
                let continuation = lock.withLock {
                    let continuation = self.continuation
                    self.continuation = nil
                    return continuation
                }
                continuation?.resume()
            }

            func recordedCallCount() -> Int { lock.withLock { callCount } }
        }

        let gate = DatabaseGate()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await gate.waitForRelease()
                return false
            },
            cacheLifetime: 60
        )

        async let firstStatuses = service.visibleStatuses()
        async let secondStatuses = service.visibleStatuses()

        try? await Task.sleep(for: .milliseconds(50))
        let initialCallCount = gate.recordedCallCount()
        XCTAssertEqual(initialCallCount, 1)

        gate.release()
        _ = await firstStatuses
        _ = await secondStatuses

        let finalCallCount = gate.recordedCallCount()
        XCTAssertEqual(finalCallCount, 1)
    }

    func testStatusForPackUsesPersistedSnapshotAcrossServiceInstancesWithinTTL() async throws {
        actor DatabaseRecorder {
            var callCount = 0

            func recordCall() {
                callCount += 1
            }

            func recordedCallCount() -> Int { callCount }
        }

        let rootPrefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CondaManager(
            rootPrefix: rootPrefix,
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let recorder = DatabaseRecorder()
        let firstService = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                await recorder.recordCall()
                return false
            },
            cacheLifetime: 60
        )

        _ = await firstService.status(for: .requiredSetupPack)

        let secondService = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in
                try? await Task.sleep(for: .milliseconds(500))
                return false
            },
            cacheLifetime: 60
        )

        let started = Date()
        _ = await secondService.status(for: .requiredSetupPack)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.2)
        let callCount = await recorder.recordedCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRequiredPackNeedsInstallWhenBBToolsExecutablesAreMissing() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let nextflowBin = await manager.environmentURL(named: "nextflow").appendingPathComponent("bin/nextflow")
        let snakemakeBin = await manager.environmentURL(named: "snakemake").appendingPathComponent("bin/snakemake")
        try FileManager.default.createDirectory(at: nextflowBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snakemakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nextflowBin.path, contents: Data("#!/bin/sh\n".utf8))
        FileManager.default.createFile(atPath: snakemakeBin.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nextflowBin.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snakemakeBin.path)

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in true }
        )
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.pack.id, "lungfish-tools")
        XCTAssertEqual(status.state, .needsInstall)
        XCTAssertEqual(status.toolStatuses.first(where: { $0.requirement.environment == "bbtools" })?.isReady, false)
        XCTAssertEqual(status.toolStatuses.first(where: { $0.requirement.environment == "fastp" })?.isReady, false)
    }

    func testRequiredPackReadyWhenAllCoreExecutablesExist() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        for requirement in PluginPack.requiredSetupPack.toolRequirements {
            let binDir = await manager.environmentURL(named: requirement.environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for executable in requirement.executables {
                let path = binDir.appendingPathComponent(executable)
                try writeSmokeReadyExecutable(
                    for: requirement,
                    executable: executable,
                    at: path
                )
            }
        }

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in true }
        )
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
    }

    func testRequiredPackAcceptsBBToolsJavaUnderLibJvmBin() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-bbtools-java-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        for requirement in PluginPack.requiredSetupPack.toolRequirements {
            let binDir = await manager.environmentURL(named: requirement.environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for executable in requirement.executables where executable != "java" {
                let path = binDir.appendingPathComponent(executable)
                try writeSmokeReadyExecutable(
                    for: requirement,
                    executable: executable,
                    at: path
                )
            }
        }

        let javaPath = await manager.environmentURL(named: "bbtools")
            .appendingPathComponent("lib/jvm/bin/java")
        try FileManager.default.createDirectory(
            at: javaPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: javaPath.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: javaPath.path)

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in true }
        )
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
    }

    func testRequiredPackNeedsInstallWhenBBToolsSmokeCheckFails() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-bbtools-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        for requirement in PluginPack.requiredSetupPack.toolRequirements {
            let binDir = await manager.environmentURL(named: requirement.environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for executable in requirement.executables {
                let path = binDir.appendingPathComponent(executable)
                try writeSmokeReadyExecutable(
                    for: requirement,
                    executable: executable,
                    at: path,
                    forceFailure: requirement.environment == "bbtools" && executable == "reformat.sh"
                )
            }
        }

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.state, .needsInstall)
        XCTAssertEqual(status.toolStatuses.first(where: { $0.requirement.environment == "bbtools" })?.isReady, false)
    }

    func testMetagenomicsPackAcceptsEsVirituExecutableName() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-metagenomics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))
        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        let executableNames: [String: String] = [
            "kraken2": "kraken2",
            "bracken": "bracken",
            "esviritu": "EsViritu",
        ]

        for requirement in pack.toolRequirements {
            let executable = try XCTUnwrap(executableNames[requirement.environment])
            let executableURL = await manager.environmentURL(named: requirement.environment)
                .appendingPathComponent("bin/\(executable)")
            try FileManager.default.createDirectory(
                at: executableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let script = "#!/bin/sh\nexit 0\n"
            try script.write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: pack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
    }

    func testMetagenomicsPackRepairsManagedLaunchersBeforeSmokeChecks() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-metagenomics-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))
        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        let kraken2 = await manager.environmentURL(named: "kraken2").appendingPathComponent("bin/kraken2")
        try FileManager.default.createDirectory(at: kraken2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: kraken2, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kraken2.path)

        let brackenBin = await manager.environmentURL(named: "bracken").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: brackenBin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(
            to: brackenBin.appendingPathComponent("python"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: brackenBin.appendingPathComponent("python").path
        )
        try "#!/usr/bin/env python\nprint('ok')\n".write(
            to: brackenBin.appendingPathComponent("est_abundance.py"),
            atomically: true,
            encoding: .utf8
        )

        let esviritu = await manager.environmentURL(named: "esviritu").appendingPathComponent("bin/EsViritu")
        try FileManager.default.createDirectory(at: esviritu.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: esviritu, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: esviritu.path)

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: pack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: brackenBin.appendingPathComponent("bracken").path))
    }

    func testRequiredPackNeedsInstallWhenMicromambaBootstrapIsMissingOrNotExecutable() async throws {
        for bootstrapMode in ["missing", "not-executable"] {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("pack-status-bootstrap-\(bootstrapMode)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sandbox) }

            let manager = CondaManager(
                rootPrefix: sandbox.appendingPathComponent("conda"),
                bundledMicromambaProvider: { nil },
                bundledMicromambaVersionProvider: { nil }
            )

            for requirement in PluginPack.requiredSetupPack.toolRequirements {
                let binDir = await manager.environmentURL(named: requirement.environment).appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
                for executable in requirement.executables {
                    let path = binDir.appendingPathComponent(executable)
                    FileManager.default.createFile(atPath: path.path, contents: Data("#!/bin/sh\n".utf8))
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
                }
            }

            let micromambaPath = await manager.micromambaPath
            switch bootstrapMode {
            case "missing":
                break
            case "not-executable":
                try FileManager.default.createDirectory(
                    at: micromambaPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: micromambaPath.path, contents: Data("#!/bin/sh\n".utf8))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: micromambaPath.path)
            default:
                XCTFail("Unexpected bootstrap mode: \(bootstrapMode)")
            }

            let service = PluginPackStatusService(
                condaManager: manager,
                databaseInstalledCheck: { _ in true }
            )
            let status = await service.status(for: .requiredSetupPack)

            XCTAssertEqual(status.state, .needsInstall, "Bootstrap mode \(bootstrapMode) should require install")
            XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
        }
    }

    func testVisibleStatusesReturnStorageUnavailableWhenConfiguredRootIsMissing() async throws {
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            databaseInstalledCheck: { _ in true },
            storageAvailability: {
                .unavailable(URL(fileURLWithPath: "/Volumes/LungfishSSD", isDirectory: true))
            }
        )

        let statuses = await service.visibleStatuses()
        guard let requiredSetup = statuses.first(where: { $0.pack.id == PluginPack.requiredSetupPack.id }) else {
            return XCTFail("Expected required setup pack status")
        }

        XCTAssertEqual(requiredSetup.state, .failed)
        XCTAssertEqual(requiredSetup.failureMessage, "Storage location unavailable")
    }

    func testInstallPackFailsFastWhenStorageIsUnavailable() async throws {
        actor CallRecorder {
            var installCalls = 0
            var databaseCalls = 0

            func recordInstall() {
                installCalls += 1
            }

            func recordDatabase() {
                databaseCalls += 1
            }

            func snapshot() -> (Int, Int) {
                (installCalls, databaseCalls)
            }
        }

        let recorder = CallRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let unavailableRoot = URL(fileURLWithPath: "/Volumes/LungfishSSD", isDirectory: true)
        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { _, _, _, _ in
                await recorder.recordInstall()
            },
            databaseInstallAction: { _, _, _ in
                await recorder.recordDatabase()
                return URL(fileURLWithPath: "/tmp/db")
            },
            storageAvailability: {
                .unavailable(unavailableRoot)
            }
        )

        do {
            try await service.install(pack: .requiredSetupPack, reinstall: false, progress: nil)
            XCTFail("Expected install to fail for unavailable storage")
        } catch let error as PluginPackStatusServiceError {
            guard case .storageUnavailable(let root) = error else {
                return XCTFail("Unexpected service error: \(error)")
            }
            XCTAssertEqual(root.standardizedFileURL, unavailableRoot.standardizedFileURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
    }

    func testInstallPackUsesReinstallWhenRequested() async throws {
        actor InstallRecorder {
            var calls: [(packages: [String], environment: String, reinstall: Bool)] = []
            func record(_ packages: [String], _ environment: String, _ reinstall: Bool) {
                calls.append((packages, environment, reinstall))
            }
            func recordedCalls() -> [(packages: [String], environment: String, reinstall: Bool)] { calls }
        }

        actor DatabaseRecorder {
            var calls: [(databaseID: String, reinstall: Bool)] = []
            func record(_ databaseID: String, _ reinstall: Bool) {
                calls.append((databaseID, reinstall))
            }
            func recordedCalls() -> [(databaseID: String, reinstall: Bool)] { calls }
        }

        let recorder = InstallRecorder()
        let databaseRecorder = DatabaseRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { packages, environment, reinstall, _ in
                await recorder.record(packages, environment, reinstall)
            },
            databaseInstallAction: { databaseID, reinstall, _ in
                await databaseRecorder.record(databaseID, reinstall)
                return URL(fileURLWithPath: "/tmp/\(databaseID)")
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: true, progress: nil)

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.map(\.environment), PluginPack.requiredSetupPack.toolRequirements
            .compactMap { $0.managedDatabaseID == nil ? $0.environment : nil }
        )
        XCTAssertTrue(calls.allSatisfy(\.reinstall))

        let databaseCalls = await databaseRecorder.recordedCalls()
        XCTAssertEqual(databaseCalls.count, 1)
        XCTAssertEqual(databaseCalls.first?.databaseID, "deacon-panhuman")
        XCTAssertTrue(databaseCalls.first?.reinstall ?? false)
    }

    func testRequiredPackInstallsBBToolsEnvironmentFromBBMapPackage() async throws {
        actor InstallRecorder {
            var calls: [(packages: [String], environment: String, reinstall: Bool)] = []
            func record(_ packages: [String], _ environment: String, _ reinstall: Bool) {
                calls.append((packages, environment, reinstall))
            }
            func recordedCalls() -> [(packages: [String], environment: String, reinstall: Bool)] { calls }
        }

        let recorder = InstallRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { packages, environment, reinstall, _ in
                await recorder.record(packages, environment, reinstall)
            },
            databaseInstallAction: { _, _, _ in
                URL(fileURLWithPath: "/tmp/deacon-panhuman")
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: false, progress: nil)

        let calls = await recorder.recordedCalls()
        let bbtoolsCall = try XCTUnwrap(calls.first(where: { $0.environment == "bbtools" }))
        XCTAssertEqual(
            bbtoolsCall.packages,
            [try XCTUnwrap(ManagedToolLock.loadFromBundle().tool(named: "bbtools")?.packageSpec)]
        )
        XCTAssertFalse(bbtoolsCall.reinstall)
    }

    func testRequiredPackInstallsHumanScrubberDatabase() async throws {
        actor DatabaseRecorder {
            var calls: [String] = []
            var fractions: [Double] = []
            func record(_ databaseID: String) {
                calls.append(databaseID)
            }
            func recordProgress(_ fraction: Double) {
                fractions.append(fraction)
            }
            func recordedCalls() -> [String] { calls }
            func recordedFractions() -> [Double] { fractions }
        }

        let recorder = DatabaseRecorder()
        final class EventRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [PluginPackInstallProgress] = []

            func record(_ event: PluginPackInstallProgress) {
                lock.withLock {
                    events.append(event)
                }
            }

            func recordedEvents() -> [PluginPackInstallProgress] {
                lock.withLock { events }
            }
        }
        let eventRecorder = EventRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { _, _, _, _ in },
            databaseInstallAction: { databaseID, _, progress in
                await recorder.record(databaseID)
                progress?(0.55, "Downloading Human Read Removal Data…")
                await recorder.recordProgress(0.55)
                return URL(fileURLWithPath: "/tmp/\(databaseID)")
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: false) { event in
            eventRecorder.record(event)
        }

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls, ["deacon-panhuman"])
        let fractions = await recorder.recordedFractions()
        XCTAssertEqual(fractions, [0.55])
        let events = eventRecorder.recordedEvents()
        XCTAssertTrue(events.contains {
            $0.requirementID == "deacon-panhuman"
                && $0.requirementDisplayName == "Human Read Removal Data"
                && abs($0.itemFraction - 0.55) < 0.0001
        })
    }

    func testInstallPackPropagatesReinstallToManagedDatabaseRequirements() async throws {
        actor DatabaseRecorder {
            var calls: [(databaseID: String, reinstall: Bool)] = []
            func record(_ databaseID: String, _ reinstall: Bool) {
                calls.append((databaseID, reinstall))
            }
            func recordedCalls() -> [(databaseID: String, reinstall: Bool)] { calls }
        }

        let recorder = DatabaseRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { _, _, _, _ in },
            databaseInstallAction: { databaseID, reinstall, _ in
                await recorder.record(databaseID, reinstall)
                return URL(fileURLWithPath: "/tmp/\(databaseID)")
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: true, progress: nil)

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.databaseID, "deacon-panhuman")
        XCTAssertEqual(calls.first?.reinstall, true)
    }

    func testInstallPackRunsPostInstallHooksAfterPackageInstalls() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        let pack = PluginPack.builtIn.first { $0.id == "wastewater-surveillance" }!
        let hookLog = await manager.rootPrefix.appendingPathComponent("hook-log.txt")

        for hook in pack.postInstallHooks {
            let envBin = await manager.environmentURL(named: hook.environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: envBin, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            printf '%s %s\n' "$0" "$*" >> "$MAMBA_ROOT_PREFIX/hook-log.txt"
            exit 0
            """
            let executable = envBin.appendingPathComponent(hook.command[0])
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { _, _, _, _ in }
        )

        try await service.install(pack: pack, reinstall: false, progress: nil)

        let log = try String(contentsOf: hookLog, encoding: .utf8)
        XCTAssertTrue(log.contains("freyja update"))
        XCTAssertTrue(log.contains("pangolin --update-data"))
        XCTAssertLessThan(
            log.range(of: "freyja update")!.lowerBound,
            log.range(of: "pangolin --update-data")!.lowerBound
        )
    }

    func testInstallPackSkipsMissingHookEnvironmentsAndContinuesAfterFailure() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-hooks-nonfatal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let micromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        let logURL = await manager.rootPrefix.appendingPathComponent("hook-log.txt")
        let missingHook = PostInstallHook(
            description: "Missing hook environment",
            environment: "missing-env",
            command: ["missing-tool"]
        )
        let failingHook = PostInstallHook(
            description: "Failing hook",
            environment: "failing-env",
            command: ["failing-tool"]
        )
        let succeedingHook = PostInstallHook(
            description: "Succeeding hook",
            environment: "succeeding-env",
            command: ["succeeding-tool"]
        )
        let pack = PluginPack(
            id: "nonfatal-hooks",
            name: "Nonfatal Hooks",
            description: "Test pack for hook handling",
            sfSymbol: "wrench.and.screwdriver",
            packages: [],
            category: "Testing",
            postInstallHooks: [missingHook, failingHook, succeedingHook]
        )

        for (environment, command, shouldFail) in [
            ("failing-env", "failing-tool", true),
            ("succeeding-env", "succeeding-tool", false),
        ] {
            let envBin = await manager.environmentURL(named: environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: envBin, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            printf '%s %s\n' "$0" "$*" >> "$MAMBA_ROOT_PREFIX/hook-log.txt"
            \(shouldFail ? "exit 1" : "exit 0")
            """
            let executable = envBin.appendingPathComponent(command)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { _, _, _, _ in }
        )

        try await service.install(pack: pack, reinstall: false, progress: nil)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("missing-tool"))
        XCTAssertTrue(log.contains("failing-tool"))
        XCTAssertTrue(log.contains("succeeding-tool"))
        XCTAssertLessThan(
            log.range(of: "failing-tool")!.lowerBound,
            log.range(of: "succeeding-tool")!.lowerBound
        )
    }

    @discardableResult
    private func makeFakeMicromamba(at url: URL, version: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "\(version)"
                exit 0
                ;;
            create|install)
                env_name=""
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -n)
                            shift
                            env_name="$1"
                            ;;
                    esac
                    shift
                done
                if [ -z "$MAMBA_ROOT_PREFIX" ] || [ -z "$env_name" ]; then
                    echo "missing root prefix or env name" >&2
                    exit 1
                fi
                mkdir -p "$MAMBA_ROOT_PREFIX/envs/$env_name/bin"
                mkdir -p "$MAMBA_ROOT_PREFIX/envs/$env_name/conda-meta"
                exit 0
                ;;
            run)
                env_name=""
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -n)
                            shift
                            env_name="$1"
                            shift
                            break
                            ;;
                    esac
                    shift
                done
                tool="$1"
                shift
                exec "$MAMBA_ROOT_PREFIX/envs/$env_name/bin/$tool" "$@"
                ;;
            remove)
                exit 0
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeSmokeReadyExecutable(
        for requirement: PackToolRequirement,
        executable: String,
        at url: URL,
        forceFailure: Bool = false
    ) throws {
        let script: String
        if forceFailure {
            script = "#!/bin/sh\nexit 1\n"
        } else if requirement.environment == "bbtools", executable == "reformat.sh" {
            script = """
            #!/bin/sh
            out=""
            for arg in "$@"; do
                case "$arg" in
                    out=*) out="${arg#out=}" ;;
                esac
            done
            if [ -n "$out" ]; then
                printf '@r1\\nACGT\\n+\\nIIII\\n' > "$out"
            fi
            exit 0
            """
        } else if let smokeTest = requirement.smokeTest,
                  smokeTest.executable == executable,
                  let requiredOutputSubstring = smokeTest.requiredOutputSubstring,
                  let exitCode = smokeTest.acceptedExitCodes.first {
            script = """
            #!/bin/sh
            printf '%s\\n' '\(requiredOutputSubstring)' >&2
            exit \(exitCode)
            """
        } else {
            script = "#!/bin/sh\nexit 0\n"
        }

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
