import CryptoKit
import Foundation
import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ManagedPythonRuntimeInstallerTests: XCTestCase {
    func testProductionRunnerCapturesCompleteLargeInventoryBeforeReturning() async throws {
        let script = """
            import json, sys
            sys.stdout.write(json.dumps({"files": ["x" * 200] * 40000, "complete": True}))
            sys.stderr.write("inventory finished\\n")
            """
        let result = try await ManagedPythonRuntimeInstaller.run(
            ["/usr/bin/python3", "-I", "-c", script], workingDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.stdout.utf8.count, 8_000_000)
        let inventory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual((inventory["files"] as? [String])?.count, 40_000)
        XCTAssertEqual(inventory["complete"] as? Bool, true)
        XCTAssertEqual(result.stderr, "inventory finished\n")
    }

    func testLiveSelectedRuntimeRepair() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["LUNGFISH_LIVE_PRIMALSCHEME_REPAIR_ROOT"],
              let logPath = ProcessInfo.processInfo.environment["LUNGFISH_RUNTIME_DIAGNOSTICS"] else {
            throw XCTSkip("Set explicit repair root and diagnostics directory for the managed upgrade proof")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let logs = URL(fileURLWithPath: logPath, isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let service = PluginPackStatusService(condaManager: CondaManager(rootPrefix: root),
            pythonRuntimeInstallAction: { requirement, environment, _ in
                let spec = try XCTUnwrap(requirement.pythonRuntime)
                let installer = ManagedPythonRuntimeInstaller(commandRunner: { argv, directory in
                    let started = Date()
                    let result = try await ManagedPythonRuntimeInstaller.run(argv, workingDirectory: directory)
                    let stem = argv.contains("-c") ? "inventory" : UUID().uuidString
                    let diagnostic: [String: Any] = ["argv": argv, "exitStatus": result.exitStatus,
                        "stdout": result.stdout, "stderr": result.stderr]
                    try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
                        .write(to: logs.appendingPathComponent(stem + ".json"))
                    return .init(exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr,
                                 wallTimeSeconds: Date().timeIntervalSince(started))
                })
                do {
                    let receipt = try await installer.install(spec: spec, environmentURL: environment,
                        executableName: try XCTUnwrap(requirement.executables.first))
                    XCTAssertTrue(receipt.validates(spec: spec, environmentURL: environment))
                } catch {
                    var diagnostic: [String: Any] = ["error": String(describing: error),
                        "condaPackages": ManagedPythonRuntimeReceipt.condaRecords(in: environment).map {
                            ["name": $0.name, "version": $0.version, "build": $0.build]
                        }]
                    if let data = try? Data(contentsOf: logs.appendingPathComponent("inventory.json")),
                       let capture = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = capture["stdout"] as? String,
                       let inventory = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                       let files = inventory["files"] as? [[String: Any]] {
                        diagnostic["inventoryFiles"] = files.count
                        diagnostic["changedFiles"] = files.compactMap { saved -> String? in
                            guard let path = saved["relativePath"] as? String else { return "missing path" }
                            guard let actual = try? ManagedPythonRuntimeReceipt.fileRecord(
                                for: environment.appendingPathComponent(path), relativeTo: environment),
                                actual.sha256 == saved["sha256"] as? String else { return path }
                            return nil
                        }
                    }
                    try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                        .write(to: logs.appendingPathComponent("failure.json"))
                    throw error
                }
            })
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "pcr-primer-design"))
        try await service.install(pack: pack, requirementIDs: ["primalscheme3"], progress: nil)
        let status = await service.status(for: pack)
        XCTAssertTrue(try XCTUnwrap(status.toolStatuses.first { $0.requirement.id == "primalscheme3" }).isReady)
    }

    func testActualMultilineRequirementsBindReleaseWheelHash() throws {
        let resource = try XCTUnwrap(RuntimeResourceLocator.path(
            "ManagedTools/primalscheme3-osx-arm64-py312-requirements.txt",
            in: .workflow))
        let requirements = try Data(contentsOf: resource)
        XCTAssertTrue(ManagedPythonRuntimeInstaller.requirementsContainPinnedWheel(
            requirements,
            contain: "primalscheme3",
            version: "3.3.0+lge.2",
            sha256: "98eeac686148aa9f14de2584f80ef845f9474969c5421890c1210aef13afe54c"))
        XCTAssertFalse(ManagedPythonRuntimeInstaller.requirementsContainPinnedWheel(
            requirements,
            contain: "primalscheme3",
            version: "3.3.0+lge.2",
            sha256: String(repeating: "0", count: 64)))
    }

    func testReleaseWheelSourceRequiresImmutableGitHubAssetIdentity() throws {
        let source = ManagedPythonRuntimeWheelSource(
            url: try XCTUnwrap(URL(string:
                "https://github.com/dhoconno/primalscheme3-lge/releases/download/v3.3.0-lge.2/primalscheme3-3.3.0+lge.2-py3-none-any.whl")),
            sha256: String(repeating: "a", count: 64),
            sourceRevision: String(repeating: "b", count: 40),
            upstreamRevision: String(repeating: "c", count: 40))

        XCTAssertNoThrow(try source.validateRequestedIdentity())
        XCTAssertThrowsError(try ManagedPythonRuntimeWheelSource(
            url: URL(string: "https://github.com/dhoconno/primalscheme3-lge/latest/wheel.whl")!,
            sha256: source.sha256,
            sourceRevision: source.sourceRevision,
            upstreamRevision: source.upstreamRevision
        ).validateRequestedIdentity())
    }

    func testRejectsUnsafeRuntimeIdentityPinsAndExecutableBasename() async throws {
        let fixture = try PythonRuntimeFixture()
        defer { fixture.cleanup() }

        let unsafeIdentity = ManagedPythonRuntimeSpec(
            distributionName: "../primalscheme3", version: fixture.spec.version,
            pythonABI: fixture.spec.pythonABI, platform: fixture.spec.platform,
            basePackageSpecs: fixture.spec.basePackageSpecs,
            requirementsResource: fixture.spec.requirementsResource,
            requirementsSHA256: fixture.spec.requirementsSHA256)
        XCTAssertThrowsError(try unsafeIdentity.validateRequestedIdentity())

        let unpinnedBase = ManagedPythonRuntimeSpec(
            distributionName: fixture.spec.distributionName, version: fixture.spec.version,
            pythonABI: fixture.spec.pythonABI, platform: fixture.spec.platform,
            basePackageSpecs: ["conda-forge::python=3.12"],
            requirementsResource: fixture.spec.requirementsResource,
            requirementsSHA256: fixture.spec.requirementsSHA256)
        XCTAssertThrowsError(try unpinnedBase.validateRequestedIdentity())

        do {
            _ = try await fixture.installer().install(
                spec: fixture.spec, environmentURL: fixture.environmentURL,
                executableName: "../primalscheme3")
            XCTFail("Expected unsafe executable rejection")
        } catch {
            XCTAssertTrue(error is ManagedPythonRuntimeInstallerError)
        }
        XCTAssertTrue(fixture.recorder.commands.isEmpty)
    }

    func testSuccessfulInstallUsesIsolatedHashedWheelOnlyCommandsAndWritesValidReceipt() async throws {
        let fixture = try PythonRuntimeFixture()
        defer { fixture.cleanup() }

        let receipt = try await fixture.installer().install(
            spec: fixture.spec,
            environmentURL: fixture.environmentURL,
            executableName: "primalscheme3"
        )

        let python = fixture.environmentURL.appendingPathComponent("bin/python").path
        XCTAssertEqual(fixture.recorder.commands.prefix(3), [
            [python, "-I", "-m", "pip", "--isolated", "download", "--require-hashes", "--only-binary=:all:", "--no-deps", "--find-links", fixture.releaseWheelURL.absoluteString, "--dest", fixture.wheelhouse.path, "-r", fixture.requirementsURL.path],
            [python, "-I", "-m", "pip", "--isolated", "install", "--require-hashes", "--no-index", "--no-deps", "--force-reinstall", "--find-links", fixture.wheelhouse.path, "-r", fixture.requirementsURL.path],
            [python, "-I", "-m", "pip", "--isolated", "check"],
        ])
        XCTAssertEqual(receipt.requested, fixture.spec)
        XCTAssertEqual(receipt.pythonVersion, "3.12.11")
        XCTAssertTrue(receipt.validates(spec: fixture.spec, environmentURL: fixture.environmentURL))
        XCTAssertEqual(
            try ManagedPythonRuntimeReceipt.load(from: fixture.receiptURL), receipt)
    }

    func testFailedPipInvalidatesStaleReceiptButPreservesExistingEnvironment() async throws {
        let fixture = try PythonRuntimeFixture(failCommandIndex: 0)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: fixture.receiptURL)
        let sentinel = fixture.environmentURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        do {
            _ = try await fixture.installer().install(
                spec: fixture.spec,
                environmentURL: fixture.environmentURL,
                executableName: "primalscheme3")
            XCTFail("Expected pip failure")
        } catch {
            XCTAssertTrue(error is ManagedPythonRuntimeInstallerError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testReceiptRejectsRequestedIdentityAndInstalledFileTampering() async throws {
        let fixture = try PythonRuntimeFixture()
        defer { fixture.cleanup() }
        let receipt = try await fixture.installer().install(
            spec: fixture.spec,
            environmentURL: fixture.environmentURL,
            executableName: "primalscheme3")
        let other = ManagedPythonRuntimeSpec(
            distributionName: "primalscheme3", version: "9.9.9", pythonABI: "cp312",
            platform: "osx-arm64", basePackageSpecs: fixture.spec.basePackageSpecs,
            requirementsResource: fixture.spec.requirementsResource,
            requirementsSHA256: fixture.spec.requirementsSHA256)
        XCTAssertFalse(receipt.validates(spec: other, environmentURL: fixture.environmentURL))
        try Data("tampered".utf8).write(to: fixture.installedFile)
        XCTAssertFalse(receipt.validates(spec: fixture.spec, environmentURL: fixture.environmentURL))
    }

    func testReceiptRejectsInstalledFileReachedThroughSymlinkedAncestor() async throws {
        let fixture = try PythonRuntimeFixture()
        defer { fixture.cleanup() }
        let receipt = try await fixture.installer().install(
            spec: fixture.spec,
            environmentURL: fixture.environmentURL,
            executableName: "primalscheme3")
        let packageDirectory = fixture.installedFile.deletingLastPathComponent()
        let relocated = fixture.root.appendingPathComponent("relocated-primalscheme3")
        try FileManager.default.moveItem(at: packageDirectory, to: relocated)
        try FileManager.default.createSymbolicLink(
            at: packageDirectory, withDestinationURL: relocated)

        XCTAssertFalse(receipt.validates(
            spec: fixture.spec, environmentURL: fixture.environmentURL))
    }

    func testCancellationNeverPublishesReceipt() async throws {
        let fixture = try PythonRuntimeFixture(cancelCommandIndex: 1)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.installer().install(
                spec: fixture.spec,
                environmentURL: fixture.environmentURL,
                executableName: "primalscheme3")
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    func testLivePinnedRuntimeInstallsThroughProductionInstaller() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_LIVE_PRIMALSCHEME_ENV"] else {
            throw XCTSkip("Set LUNGFISH_LIVE_PRIMALSCHEME_ENV to run the native installer proof")
        }
        let requirement = try XCTUnwrap(
            PluginPack.activeOptionalPacks.first { $0.id == "pcr-primer-design" }?
                .toolRequirements.first { $0.id == "primalscheme3" })
        let runtime = try XCTUnwrap(requirement.pythonRuntime)

        let receipt = try await ManagedPythonRuntimeInstaller().install(
            spec: runtime,
            environmentURL: URL(fileURLWithPath: path, isDirectory: true),
            executableName: "primalscheme3")

        XCTAssertTrue(receipt.validates(
            spec: runtime,
            environmentURL: URL(fileURLWithPath: path, isDirectory: true)))
        XCTAssertEqual(receipt.installedDistributions.count, 30)
        XCTAssertTrue(receipt.versionProbe.output.contains("3.3.0"))
        XCTAssertTrue(receipt.helpProbe.output.localizedCaseInsensitiveContains("usage"))
    }
}

private final class PythonCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    var commands: [[String]] { lock.withLock { stored } }
    func append(_ argv: [String]) -> Int {
        lock.withLock {
            stored.append(argv)
            return stored.count - 1
        }
    }
}

private struct PythonRuntimeFixture {
    static let wheelBytes = Data("wheel".utf8)
    static let wheelHash = SHA256.hash(data: wheelBytes).map { String(format: "%02x", $0) }.joined()
    static var requirementsBytes: Data {
        Data("primalscheme3==3.3.0 --hash=sha256:\(wheelHash)\n".utf8)
    }
    let root: URL
    let environmentURL: URL
    let spec: ManagedPythonRuntimeSpec
    let recorder = PythonCommandRecorder()
    let failCommandIndex: Int?
    let cancelCommandIndex: Int?

    var managedDirectory: URL { environmentURL.appendingPathComponent("share/lungfish/managed-tools") }
    var requirementsURL: URL { managedDirectory.appendingPathComponent(spec.requirementsResource) }
    var wheelhouse: URL { managedDirectory.appendingPathComponent("wheels-primalscheme3") }
    var receiptURL: URL { ManagedPythonRuntimeReceipt.receiptURL(for: spec, environmentURL: environmentURL) }
    var installedFile: URL { environmentURL.appendingPathComponent("lib/python3.12/site-packages/primalscheme3/__init__.py") }
    var requirementsData: Data { Self.requirementsBytes }
    var releaseWheelURL: URL {
        URL(string: "https://github.com/example/runtime/releases/download/v3.3.0/primalscheme3-3.3.0-py3-none-any.whl")!
    }

    init(failCommandIndex: Int? = nil, cancelCommandIndex: Int? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        environmentURL = root.appendingPathComponent("env", isDirectory: true)
        self.failCommandIndex = failCommandIndex
        self.cancelCommandIndex = cancelCommandIndex
        let hash = SHA256.hash(data: Self.requirementsBytes).map { String(format: "%02x", $0) }.joined()
        spec = ManagedPythonRuntimeSpec(
            distributionName: "primalscheme3", version: "3.3.0", pythonABI: "cp312",
            platform: "osx-arm64",
            basePackageSpecs: [
                "conda-forge::python=3.12.11=hc22306f_0_cpython",
                "conda-forge::pip=25.2=pyh8b19718_0",
                "bioconda::primer3-py=2.3.1=py312h76eea60_0",
            ],
            requirementsResource: "requirements.txt", requirementsSHA256: hash,
            releaseWheelSource: .init(
                url: URL(string: "https://github.com/example/runtime/releases/download/v3.3.0/primalscheme3-3.3.0-py3-none-any.whl")!,
                sha256: Self.wheelHash,
                sourceRevision: String(repeating: "a", count: 40),
                upstreamRevision: String(repeating: "b", count: 40)))
        try FileManager.default.createDirectory(
            at: environmentURL.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: environmentURL.appendingPathComponent("conda-meta"), withIntermediateDirectories: true)
        for executable in ["python", "primalscheme3"] {
            let url = environmentURL.appendingPathComponent("bin/\(executable)")
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for (name, version, build, subdir) in [
            ("python", "3.12.11", "hc22306f_0_cpython", "osx-arm64"),
            ("pip", "25.2", "pyh8b19718_0", "noarch"),
            ("primer3-py", "2.3.1", "py312h76eea60_0", "osx-arm64"),
        ] {
            let json = try JSONSerialization.data(withJSONObject: [
                "name": name, "version": version, "build": build, "subdir": subdir,
            ])
            try json.write(to: environmentURL.appendingPathComponent("conda-meta/\(name).json"))
        }
    }

    func installer() -> ManagedPythonRuntimeInstaller {
        let environmentURL = self.environmentURL
        let requirementsData = self.requirementsData
        let recorder = self.recorder
        let failCommandIndex = self.failCommandIndex
        let cancelCommandIndex = self.cancelCommandIndex
        let installedFile = self.installedFile
        return ManagedPythonRuntimeInstaller(
            requirementsProvider: { _ in requirementsData },
            commandRunner: { argv, _ in
                let index = recorder.append(argv)
                if index == cancelCommandIndex { throw CancellationError() }
                if index == failCommandIndex {
                    return .init(exitStatus: 2, stdout: "", stderr: "injected pip failure", wallTimeSeconds: 0.1)
                }
                if argv.contains("download") {
                    let wheelhouse = environmentURL.appendingPathComponent("share/lungfish/managed-tools/wheels-primalscheme3")
                    try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
                    try Self.wheelBytes.write(to: wheelhouse.appendingPathComponent("primalscheme3-3.3.0-py3-none-any.whl"))
                }
                if argv.contains("-c") {
                    try FileManager.default.createDirectory(at: installedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let bytes = Data("__version__ = '3.3.0'\n".utf8)
                    try bytes.write(to: installedFile)
                    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let object: [String: Any] = [
                        "distributions": [["name": "primalscheme3", "version": "3.3.0"]],
                        "files": [[
                            "relativePath": "lib/python3.12/site-packages/primalscheme3/__init__.py",
                            "sha256": hash, "sizeBytes": bytes.count,
                        ]],
                    ]
                    return .init(exitStatus: 0, stdout: String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!, stderr: "", wallTimeSeconds: 0.1)
                }
                if argv.last == "--version" {
                    return .init(exitStatus: 0, stdout: "primalscheme3 3.3.0\n", stderr: "", wallTimeSeconds: 0.1)
                }
                if argv.last == "--help" {
                    return .init(exitStatus: 0, stdout: "Usage: primalscheme3\n", stderr: "", wallTimeSeconds: 0.1)
                }
                return .init(exitStatus: 0, stdout: "", stderr: "", wallTimeSeconds: 0.1)
            },
            now: { Date(timeIntervalSince1970: 100) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
