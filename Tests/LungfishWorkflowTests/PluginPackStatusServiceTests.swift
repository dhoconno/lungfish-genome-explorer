import XCTest
@testable import LungfishWorkflow

final class PluginPackStatusServiceTests: XCTestCase {

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

        let service = PluginPackStatusService(condaManager: manager)
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
                FileManager.default.createFile(atPath: path.path, contents: Data("#!/bin/sh\n".utf8))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
        }

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
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

            let service = PluginPackStatusService(condaManager: manager)
            let status = await service.status(for: .requiredSetupPack)

            XCTAssertEqual(status.state, .needsInstall, "Bootstrap mode \(bootstrapMode) should require install")
            XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
        }
    }

    func testInstallPackUsesReinstallWhenRequested() async throws {
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
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: true, progress: nil)

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.map(\.environment), ["nextflow", "snakemake", "bbtools", "fastp"])
        XCTAssertTrue(calls.allSatisfy(\.reinstall))
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
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: false, progress: nil)

        let calls = await recorder.recordedCalls()
        let bbtoolsCall = try XCTUnwrap(calls.first(where: { $0.environment == "bbtools" }))
        XCTAssertEqual(bbtoolsCall.packages, ["bbmap"])
        XCTAssertFalse(bbtoolsCall.reinstall)
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
}
