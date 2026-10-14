import XCTest
import LungfishCore
@testable import LungfishCLI

final class WorkflowEngineLaunchTests: XCTestCase {

    func testAvailabilityRejectsRelativePATHBeforeAResolvedAbsoluteEngine() throws {
        let home = try makeTemporaryHome("relative-path")
        defer { try? FileManager.default.removeItem(at: home) }
        let launch = WorkflowEngineLaunch.resolve(executableName: "invented-fixture-engine", homeDirectory: home,
            baseEnvironment: ["PATH": "relative-bin:/fixture/absolute"])
        XCTAssertEqual(launch.executableURL.path, "/usr/bin/env", "Ordinary launch behavior remains unchanged")
        XCTAssertNil(launch.resolvedExecutableURL(isExecutable: { $0 == "/fixture/absolute/invented-fixture-engine" }),
                     "A relative earlier entry may resolve differently in the eventual engine working directory")
    }

    func testAvailabilityUsesManagedExecutableWithoutLaunchingIt() throws {
        let home = try makeTemporaryHome("availability-managed")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = try installStubExecutable(named: "nextflow",
            in: home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin"))
        let launch = WorkflowEngineLaunch.resolve(executableName: "nextflow", homeDirectory: home, appIdentity: .preview)
        XCTAssertEqual(launch.resolvedExecutableURL()?.path, executable.path)
    }

    func testAvailabilityUsesEffectivePATHOrderAndRejectsMissingEngine() throws {
        let home = try makeTemporaryHome("availability-path")
        defer { try? FileManager.default.removeItem(at: home) }
        let launch = WorkflowEngineLaunch.resolve(executableName: "invented-fixture-engine", homeDirectory: home,
            baseEnvironment: ["PATH": "/fixture/first:/fixture/second"])
        let paths = ["/fixture/first/invented-fixture-engine", "/fixture/second/invented-fixture-engine"]
        XCTAssertEqual(launch.resolvedExecutableURL(isExecutable: { paths.contains($0) })?.path, paths[0])
        XCTAssertNil(launch.resolvedExecutableURL(isExecutable: { _ in false }))
    }

    private func makeTemporaryHome(_ label: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-engine-launch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func installStubExecutable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/bash\necho stub \(name)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func testPrefersManagedNextflowOverPATHLookup() throws {
        let home = try makeTemporaryHome("managed")
        defer { try? FileManager.default.removeItem(at: home) }
        let managedBin = home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true)
        let managedExecutable = try installStubExecutable(named: "nextflow", in: managedBin)
        let condaBin = home.appendingPathComponent(".lungfish/conda/bin", isDirectory: true)

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent"]
        )

        XCTAssertEqual(launch.executableURL.standardizedFileURL.path, managedExecutable.standardizedFileURL.path)
        XCTAssertEqual(launch.argumentPrefix, [])
        XCTAssertEqual(launch.arguments(["run", "nf-core/viralrecon"]), ["run", "nf-core/viralrecon"])

        let path = (launch.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, managedBin.standardizedFileURL.path)
        XCTAssertTrue(path.contains(condaBin.standardizedFileURL.path), path.joined(separator: ":"))
        XCTAssertTrue(path.contains("/usr/local/bin"), "Docker Desktop's CLI lives in /usr/local/bin")
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertTrue(path.contains("/bin"))
        XCTAssertEqual(launch.environment["HOME"], home.path)
        XCTAssertEqual(launch.environment["NXF_ANSI_LOG"], "false")
        XCTAssertNotNil(launch.environment["NXF_HOME"])
    }

    func testFallsBackToPATHLookupWithToolPathsWhenManagedCopyMissing() throws {
        let home = try makeTemporaryHome("fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let condaBin = home.appendingPathComponent(".lungfish/conda/bin", isDirectory: true)

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(launch.argumentPrefix, ["nextflow"])
        XCTAssertEqual(launch.arguments(["-version"]), ["nextflow", "-version"])

        let path = (launch.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains(condaBin.standardizedFileURL.path), path.joined(separator: ":"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }

    func testPATHEntriesAreNotDuplicated() throws {
        let home = try makeTemporaryHome("dedupe")
        defer { try? FileManager.default.removeItem(at: home) }
        let managedBin = home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true)
        _ = try installStubExecutable(named: "nextflow", in: managedBin)

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/local/bin:/usr/bin:\(managedBin.standardizedFileURL.path)"]
        )

        let path = (launch.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(path.count, Set(path).count, path.joined(separator: ":"))
        XCTAssertEqual(path.first, managedBin.standardizedFileURL.path)
    }

    func testManagedLaunchPointsJavaHomeAtBundledJDK() throws {
        let home = try makeTemporaryHome("jdk")
        defer { try? FileManager.default.removeItem(at: home) }
        let envRoot = home.appendingPathComponent(".lungfish/conda/envs/nextflow", isDirectory: true)
        _ = try installStubExecutable(named: "nextflow", in: envRoot.appendingPathComponent("bin", isDirectory: true))
        let jvmHome = envRoot.appendingPathComponent("lib/jvm", isDirectory: true)
        _ = try installStubExecutable(named: "java", in: jvmHome.appendingPathComponent("bin", isDirectory: true))

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "JAVA_HOME": "/Library/Java/Elsewhere"]
        )

        // Conda's activation script exports JAVA_HOME=$CONDA_PREFIX/lib/jvm; a direct
        // launch never runs it, and without a system JDK the launcher then fails.
        XCTAssertEqual(launch.environment["JAVA_HOME"], jvmHome.standardizedFileURL.path)
    }

    func testJavaHomeIsLeftAloneWithoutBundledJDK() throws {
        let home = try makeTemporaryHome("nojdk")
        defer { try? FileManager.default.removeItem(at: home) }
        let managedBin = home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true)
        _ = try installStubExecutable(named: "nextflow", in: managedBin)

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "JAVA_HOME": "/Library/Java/Elsewhere"]
        )

        XCTAssertEqual(launch.environment["JAVA_HOME"], "/Library/Java/Elsewhere")
    }

    func testSnakemakeLaunchResolvesManagedCopyWithoutNextflowVariables() throws {
        let home = try makeTemporaryHome("snakemake")
        defer { try? FileManager.default.removeItem(at: home) }
        let managedBin = home.appendingPathComponent(".lungfish/conda/envs/snakemake/bin", isDirectory: true)
        let managedExecutable = try installStubExecutable(named: "snakemake", in: managedBin)

        let launch = WorkflowEngineLaunch.resolve(
            executableName: "snakemake",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executableURL.standardizedFileURL.path, managedExecutable.standardizedFileURL.path)
        XCTAssertEqual(launch.argumentPrefix, [])
        XCTAssertNil(launch.environment["NXF_ANSI_LOG"])
        XCTAssertNil(launch.environment["NXF_HOME"])
    }

    /// Phase 2.10 V3-BIO 4. Nextflow 26.04 prints its agent log, which has no banner, no `Launching` line and none of the
    /// task lines the progress reader reads, when `NXF_AGENT_MODE`, `AGENT` or `CLAUDECODE` holds `true` or `1`
    /// (`nextflow.SysEnv.isAgentMode`). A coding agent's shell sets `CLAUDECODE`, and a launch copies its parent's
    /// environment, so a run started from one lost the record's `resolvedCommit` and its progress. The Nextflow launch
    /// switches all three off, the managed copy's and the `PATH` lookup's alike, and keeps every other variable of the
    /// base. They are set to `false` and not taken out, because the spawn lays the launch over its own process's
    /// environment, which a name left out of the launch does not change (the next test).
    func testTheNextflowLaunchDropsTheAgentModeSwitches() throws {
        let home = try makeTemporaryHome("agent-mode")
        defer { try? FileManager.default.removeItem(at: home) }
        let managedBin = home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true)
        _ = try installStubExecutable(named: "nextflow", in: managedBin)
        let base = [
            "PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "NXF_AGENT_MODE": "true", "AGENT": "1", "NXF_OPTS": "-Xmx1g", "NO_COLOR": "1",
        ]
        let switches = ["CLAUDECODE", "NXF_AGENT_MODE", "AGENT"]

        let managed = try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview, baseEnvironment: base)
        XCTAssertTrue(managed.usesManagedExecutable)
        for name in switches {
            XCTAssertEqual(managed.environment[name], "false", "the managed launch left \(name) on")
        }
        XCTAssertEqual(managed.environment["NXF_OPTS"], "-Xmx1g", "only the three switches change")
        XCTAssertEqual(managed.environment["NO_COLOR"], "1", "only the three switches change")
        XCTAssertEqual(managed.environment["NXF_ANSI_LOG"], "false")

        let lookupHome = try makeTemporaryHome("agent-mode-lookup")
        defer { try? FileManager.default.removeItem(at: lookupHome) }
        let lookup = WorkflowEngineLaunch.resolve(
            executableName: "nextflow", homeDirectory: lookupHome, appIdentity: .preview, baseEnvironment: base)
        XCTAssertFalse(lookup.usesManagedExecutable)
        for name in switches {
            XCTAssertEqual(lookup.environment[name], "false", "the PATH lookup left \(name) on")
        }
        XCTAssertEqual(lookup.environment["NXF_OPTS"], "-Xmx1g")

        // A base that holds no switch gets them off as well, since the spawn lays the launch over its own process's.
        let bare = WorkflowEngineLaunch.resolve(
            executableName: "nextflow", homeDirectory: lookupHome, appIdentity: .preview, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        for name in switches {
            XCTAssertEqual(bare.environment[name], "false", "a bare base left \(name) unset")
        }
    }

    /// FXV3 item 4, the live confirmation. `ProcessManager` lays a launch's environment over the environment of the process
    /// that spawns it, so a name taken out of the launch is still inherited, and the first fix, which only removed
    /// `CLAUDECODE` from the launch, left the Nextflow that `lungfish-cli` started in agent mode (FXV3 live run, no banner
    /// and no `Launching` line). This test holds the three switches on in its own process, runs a stand-in `nextflow`
    /// through the real runner, and reads what that child sees.
    func testTheSpawnedNextflowSeesTheAgentModeSwitchesOff() async throws {
        let home = try makeTemporaryHome("agent-mode-spawn")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("stub-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("nextflow")
        try """
        #!/bin/bash
        echo "CLAUDECODE=${CLAUDECODE-unset} NXF_AGENT_MODE=${NXF_AGENT_MODE-unset} AGENT=${AGENT-unset}"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let names = ["CLAUDECODE", "NXF_AGENT_MODE", "AGENT"]
        let saved = names.map { ProcessInfo.processInfo.environment[$0] }
        for name in names { setenv(name, "1", 1) }
        defer {
            for (name, value) in zip(names, saved) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let base = ProcessInfo.processInfo.environment.merging(["PATH": "\(bin.path):/usr/bin:/bin"]) { _, path in path }
        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview, baseEnvironment: base)
        XCTAssertFalse(launch.usesManagedExecutable, "the stand-in is found on PATH, so no managed engine is repaired")
        let runner = ProcessNFCoreWorkflowProcessRunner(homeDirectory: home, resolveLaunch: { _, _ in launch })

        let result = try await runner.runNextflow(NFCoreWorkflowLaunch(
            arguments: [], profile: "docker",
            workingDirectory: home.appendingPathComponent("launch", isDirectory: true),
            workDirectory: home.appendingPathComponent("work", isDirectory: true),
            environment: [:], logFile: home.appendingPathComponent("logs/nextflow.log")))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "CLAUDECODE=false NXF_AGENT_MODE=false AGENT=false", "the spawned Nextflow inherited an agent switch")
    }
}
