// NextflowLaunchEnvironmentTests.swift - Every Nextflow launch gets its environment from WorkflowEngineLaunch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// R7. TaxTriage, pbAA, `NextflowRunner` and `BaseWorkflowRunner` start
/// Nextflow with the environment ``WorkflowEngineLaunch`` builds, so each one
/// gets the managed engine's bundled JDK as `JAVA_HOME` and a Mac without a
/// system JDK can still run them.
///
/// The stub engines write the environment they were started with to a file,
/// so the end-to-end cases check what the launched process saw rather than
/// what the Swift code meant to pass.
final class NextflowLaunchEnvironmentTests: XCTestCase {

    // MARK: - Shared launch

    /// The plan's risk register asks for a run on a Mac without a JDK. The
    /// injected probe describes that Mac whatever this one has installed.
    func testSharedLaunchSetsBundledJavaHomeWithoutConsultingASystemJDK() throws {
        let home = URL(fileURLWithPath: "/Users/no-jdk", isDirectory: true)
        let envRoot = CoreToolLocator.environmentURL(named: "nextflow", homeDirectory: home, appIdentity: .preview)
            .standardizedFileURL
        let managedNextflow = envRoot.appendingPathComponent("bin/nextflow").path
        let bundledJava = envRoot.appendingPathComponent("lib/jvm/bin/java").path
        let baseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path]

        var askedPaths: [String] = []
        let launch = try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: baseEnvironment,
            isExecutable: { path in
                askedPaths.append(path)
                return path == managedNextflow || path == bundledJava
            }
        )

        XCTAssertEqual(launch.executableURL.path, managedNextflow)
        XCTAssertEqual(launch.environment["JAVA_HOME"], envRoot.appendingPathComponent("lib/jvm").path)
        XCTAssertEqual(
            Set(askedPaths),
            [managedNextflow, bundledJava],
            "The launch must not depend on /usr/bin/java, /Library/Java or any other system JDK"
        )

        let withoutBundledJDK = try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: baseEnvironment,
            isExecutable: { $0 == managedNextflow }
        )
        XCTAssertNil(withoutBundledJDK.environment["JAVA_HOME"])
    }

    func testOverridingEnvironmentChangesOnlyTheNamedVariables() throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let launch = WorkflowEngineLaunch.resolve(
            executableName: "nextflow",
            homeDirectory: toolRoot.home,
            appIdentity: .preview,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "KEEP": "kept", "DROP": "dropped", "BOTH": "inherited"]
        )

        let overridden = launch.overridingEnvironment(
            set: ["ADDED": "added", "BOTH": "stated"],
            unset: ["DROP", "BOTH"]
        )

        var expected = launch.environment
        expected.removeValue(forKey: "DROP")
        expected["ADDED"] = "added"
        expected["BOTH"] = "stated"
        XCTAssertEqual(overridden.environment, expected)
        XCTAssertEqual(overridden.executableURL, launch.executableURL)
        XCTAssertEqual(overridden.argumentPrefix, launch.argumentPrefix)
        XCTAssertEqual(overridden.environment["KEEP"], "kept")
    }

    // MARK: - TaxTriage

    /// TaxTriage starts `micromamba run -n nextflow nextflow ...` with the
    /// shared environment plus two stated overrides. It keeps micromamba's root
    /// and drops Nextflow's conda settings for the docker profile.
    func testTaxTriageDockerRunUsesTheSharedLaunchPlusItsStatedOverrides() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let reads = toolRoot.root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let output = toolRoot.root.appendingPathComponent("taxtriage-output", isDirectory: true)
        let pipeline = TaxTriagePipeline(
            condaManager: CondaManager(rootPrefix: toolRoot.condaRoot),
            homeDirectoryProvider: { toolRoot.home },
            appIdentity: .preview,
            containerRuntimeProbe: ReachableDockerProbe()
        )

        let result = try await pipeline.run(config: TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: reads, platform: .illumina)],
            outputDirectory: output,
            profile: "docker",
            revision: "fixture-revision"
        ))
        XCTAssertEqual(result.exitCode, 0)

        let shared = try toolRoot.sharedLaunch()
        let jvmHome = toolRoot.jvmHome.standardizedFileURL.path

        // The version probe launches Nextflow directly with the shared environment.
        let probe = try StubNextflowToolRoot.readDump(toolRoot.nextflowDump)
        XCTAssertEqual(probe, StubNextflowToolRoot.dumped(shared.environment))
        XCTAssertEqual(probe["JAVA_HOME"], jvmHome)

        // ProcessManager layers a launch environment over the parent's, so a
        // parent that carries a removed name would hand it back to the child.
        // testTaxTriageDockerProfileRemovesInheritedCondaSettings pins the removal.
        let removedNames: Set<String> = ["NXF_CONDA_ENABLED", "NXF_CONDA_CACHEDIR"]
        let expected = shared.overridingEnvironment(
            set: ["MAMBA_ROOT_PREFIX": toolRoot.condaRoot.standardizedFileURL.path],
            unset: removedNames
        )
        let launcher = try StubNextflowToolRoot.readDump(toolRoot.micromambaDump)
        XCTAssertEqual(
            launcher.filter { !removedNames.contains($0.key) },
            StubNextflowToolRoot.dumped(expected.environment).filter { !removedNames.contains($0.key) }
        )
        XCTAssertEqual(launcher["JAVA_HOME"], jvmHome)
        XCTAssertEqual(launcher["MAMBA_ROOT_PREFIX"], toolRoot.condaRoot.standardizedFileURL.path)
        XCTAssertEqual(
            launcher["PATH"]?.split(separator: ":").first.map(String.init),
            toolRoot.managedNextflow.deletingLastPathComponent().standardizedFileURL.path
        )
    }

    func testTaxTriageCondaProfileAddsLungfishCondaSettingsToTheSharedLaunch() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let condaManager = CondaManager(rootPrefix: toolRoot.condaRoot)
        let pipeline = TaxTriagePipeline(
            condaManager: condaManager,
            homeDirectoryProvider: { toolRoot.home },
            appIdentity: .preview
        )
        let baseEnvironment = ["PATH": "/usr/bin:/bin", "KEEP": "kept"]

        let environment = await pipeline.buildLaunchEnvironment(
            useNextflowConda: true,
            baseEnvironment: baseEnvironment
        )

        let condaSettings = await condaManager.nextflowCondaConfig()
        XCTAssertEqual(condaSettings["MAMBA_ROOT_PREFIX"], toolRoot.condaRoot.standardizedFileURL.path)
        let shared = try toolRoot.sharedLaunch(baseEnvironment: baseEnvironment)
        XCTAssertEqual(environment, shared.overridingEnvironment(set: condaSettings).environment)
        XCTAssertEqual(environment["NXF_CONDA_ENABLED"], "true")
        XCTAssertEqual(
            environment["NXF_CONDA_CACHEDIR"],
            toolRoot.condaRoot.appendingPathComponent("envs").standardizedFileURL.path
        )
        XCTAssertEqual(environment["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
        XCTAssertEqual(environment["KEEP"], "kept")
    }

    func testTaxTriageDockerProfileRemovesInheritedCondaSettings() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let pipeline = TaxTriagePipeline(
            condaManager: CondaManager(rootPrefix: toolRoot.condaRoot),
            homeDirectoryProvider: { toolRoot.home },
            appIdentity: .preview
        )
        let baseEnvironment = [
            "PATH": "/usr/bin:/bin",
            "KEEP": "kept",
            "NXF_CONDA_ENABLED": "true",
            "NXF_CONDA_CACHEDIR": "/inherited/conda/envs",
        ]

        let environment = await pipeline.buildLaunchEnvironment(
            useNextflowConda: false,
            baseEnvironment: baseEnvironment
        )

        XCTAssertNil(environment["NXF_CONDA_ENABLED"])
        XCTAssertNil(environment["NXF_CONDA_CACHEDIR"])
        let shared = try toolRoot.sharedLaunch(baseEnvironment: baseEnvironment)
        XCTAssertEqual(environment, shared.overridingEnvironment(
            set: ["MAMBA_ROOT_PREFIX": toolRoot.condaRoot.standardizedFileURL.path],
            unset: ["NXF_CONDA_ENABLED", "NXF_CONDA_CACHEDIR"]
        ).environment)
        XCTAssertEqual(environment["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
        XCTAssertEqual(environment["KEEP"], "kept")
    }

    // MARK: - pbAA

    func testPBAARunLaunchesManagedNextflowWithTheSharedEnvironment() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let runner = ProcessPBAANextflowRunner(
            condaManager: CondaManager(rootPrefix: toolRoot.condaRoot),
            homeDirectoryProvider: { toolRoot.home },
            appIdentity: .preview
        )
        let workflowDirectory = toolRoot.root.appendingPathComponent("pbaa-workflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)

        let result = try await runner.run(request: toolRoot.pbaaRequest(), workflowDirectory: workflowDirectory)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.argv.first, toolRoot.managedNextflow.standardizedFileURL.path)
        let shared = try toolRoot.sharedLaunch()
        let launched = try StubNextflowToolRoot.readDump(toolRoot.nextflowDump)
        XCTAssertEqual(launched, StubNextflowToolRoot.dumped(shared.environment))
        XCTAssertEqual(launched["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
    }

    func testPBAAGetsBundledJavaHomeWithoutASystemJDK() throws {
        let home = URL(fileURLWithPath: "/Users/no-jdk", isDirectory: true)
        let envRoot = CoreToolLocator.environmentURL(named: "nextflow", homeDirectory: home, appIdentity: .preview)
            .standardizedFileURL
        let onlyManagedEngineAndBundledJDK: (String) -> Bool = {
            $0 == envRoot.appendingPathComponent("bin/nextflow").path
                || $0 == envRoot.appendingPathComponent("lib/jvm/bin/java").path
        }

        let launch = try XCTUnwrap(ProcessPBAANextflowRunner(
            homeDirectoryProvider: { home },
            appIdentity: .preview
        ).nextflowLaunch(baseEnvironment: ["PATH": "/usr/bin:/bin"], isExecutable: onlyManagedEngineAndBundledJDK))

        XCTAssertEqual(launch.environment["JAVA_HOME"], envRoot.appendingPathComponent("lib/jvm").path)
    }

    /// The `/usr/bin/env which nextflow` fallback is gone. A copy on PATH is a
    /// different, unpinned release, so pbAA reports Nextflow as unavailable.
    func testPBAAIgnoresANextflowOnPATHWhenTheManagedCopyIsMissing() async throws {
        let root = try TestTempDirectory.make(prefix: "pbaa-no-managed-nextflow")
        defer { TestTempDirectory.cleanup(root) }
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        try StubNextflowToolRoot.installScript("#!/bin/sh\necho host nextflow\n", at: pathBin.appendingPathComponent("nextflow"))
        let runner = ProcessPBAANextflowRunner(
            condaManager: CondaManager(rootPrefix: root.appendingPathComponent("conda", isDirectory: true)),
            homeDirectoryProvider: { root.appendingPathComponent("home", isDirectory: true) },
            appIdentity: .preview
        )

        XCTAssertNil(runner.nextflowLaunch(baseEnvironment: ["PATH": "\(pathBin.path):/usr/bin:/bin"]))
        do {
            _ = try await runner.run(
                request: try PBAAClusteringRunRequest(
                    inputFASTQURL: root.appendingPathComponent("reads.fastq"),
                    guideSourceURL: root.appendingPathComponent("guides.fasta"),
                    outputDirectory: root.appendingPathComponent("out", isDirectory: true),
                    outputName: "missing-engine"
                ),
                workflowDirectory: root
            )
            XCTFail("pbAA must not launch without the managed Nextflow")
        } catch let error as PBAAClusteringError {
            XCTAssertEqual(error, .nextflowUnavailable)
        }
    }

    // MARK: - NextflowRunner and BaseWorkflowRunner

    func testNextflowRunnerVersionProbeLaunchesWithTheSharedEnvironment() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let runner = NextflowRunner(homeDirectoryProvider: { toolRoot.home }, appIdentity: .preview)

        let version = await runner.getVersion()

        XCTAssertEqual(version, StubNextflowToolRoot.version)
        let shared = try toolRoot.sharedLaunch()
        let launched = try StubNextflowToolRoot.readDump(toolRoot.nextflowDump)
        XCTAssertEqual(launched, StubNextflowToolRoot.dumped(shared.environment))
        XCTAssertEqual(launched["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
    }

    func testNextflowRunnerLaunchIsTheSharedLaunchPlusCondaSettingsForTheCondaProfile() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let runner = NextflowRunner(homeDirectoryProvider: { toolRoot.home }, appIdentity: .preview)
        let baseEnvironment = ["PATH": "/usr/bin:/bin"]
        let shared = try toolRoot.sharedLaunch(baseEnvironment: baseEnvironment)

        let plain = await runner.nextflowLaunch(useConda: false, baseEnvironment: baseEnvironment)
        let conda = await runner.nextflowLaunch(useConda: true, baseEnvironment: baseEnvironment)

        XCTAssertEqual(plain, shared)
        let condaSettings = await CondaManager.shared.nextflowCondaConfig()
        XCTAssertEqual(conda, shared.overridingEnvironment(set: condaSettings))
        XCTAssertEqual(conda?.environment["NXF_CONDA_ENABLED"], "true")
        XCTAssertEqual(conda?.environment["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
    }

    func testBaseWorkflowRunnerVersionProbeLaunchesWithTheSharedEnvironment() async throws {
        let toolRoot = try StubNextflowToolRoot()
        defer { toolRoot.cleanup() }
        let runner = BaseWorkflowRunner(
            category: "NextflowLaunchEnvironmentTests",
            homeDirectoryProvider: { toolRoot.home },
            appIdentity: .preview
        )

        let version = await runner.getEngineVersion(.nextflow)

        XCTAssertEqual(version, "nextflow version \(StubNextflowToolRoot.version)")
        let shared = try toolRoot.sharedLaunch()
        let launched = try StubNextflowToolRoot.readDump(toolRoot.nextflowDump)
        XCTAssertEqual(launched, StubNextflowToolRoot.dumped(shared.environment))
        XCTAssertEqual(launched["JAVA_HOME"], toolRoot.jvmHome.standardizedFileURL.path)
    }
}

// MARK: - Fixtures

/// A temporary Preview tool root with a stub managed Nextflow and a stub JDK
/// beside it, plus a separate conda root holding a stub micromamba.
///
/// The injected conda root deliberately differs from the tool root's own, so
/// TaxTriage's stated `MAMBA_ROOT_PREFIX` override is visible.
private struct StubNextflowToolRoot {
    static let version = "26.04.6"
    static let unset = "__unset__"
    static let dumpedNames = [
        "PATH", "HOME", "JAVA_HOME", "NXF_HOME", "NXF_ANSI_LOG",
        "MAMBA_ROOT_PREFIX", "NXF_CONDA_ENABLED", "NXF_CONDA_CACHEDIR",
    ]

    let root: URL
    let home: URL
    let managedNextflow: URL
    let jvmHome: URL
    let condaRoot: URL
    /// Rewritten by the stub Nextflow every time it starts.
    let nextflowDump: URL
    /// Written by the stub micromamba on `run`.
    let micromambaDump: URL

    init() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-launch-environment")
        home = root.appendingPathComponent("home", isDirectory: true)
        let envRoot = home.appendingPathComponent(".lungfish/conda/envs/nextflow", isDirectory: true)
        // Every stub stays inside the temporary root, even if a storage setting
        // pointed the Preview tool root somewhere else.
        let resolvedEnvRoot = CoreToolLocator.environmentURL(named: "nextflow", homeDirectory: home, appIdentity: .preview)
        guard resolvedEnvRoot.standardizedFileURL.path == envRoot.standardizedFileURL.path else {
            TestTempDirectory.cleanup(root)
            throw XCTSkip("The Preview tool root resolves to \(resolvedEnvRoot.path), outside the temporary home")
        }
        managedNextflow = envRoot.appendingPathComponent("bin/nextflow")
        jvmHome = envRoot.appendingPathComponent("lib/jvm", isDirectory: true)
        condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        nextflowDump = root.appendingPathComponent("nextflow-environment.txt")
        micromambaDump = root.appendingPathComponent("micromamba-environment.txt")

        try Self.installScript(Self.nextflowScript(dump: nextflowDump), at: managedNextflow)
        try Self.installScript("#!/bin/sh\nexit 0\n", at: jvmHome.appendingPathComponent("bin/java"))
        try Self.installScript(
            Self.micromambaScript(dump: micromambaDump),
            at: condaRoot.appendingPathComponent("bin/micromamba")
        )
    }

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    /// The launch every caller must start from, for this tool root.
    func sharedLaunch(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WorkflowEngineLaunch {
        try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow",
            homeDirectory: home,
            appIdentity: .preview,
            baseEnvironment: baseEnvironment
        )
    }

    func pbaaRequest() throws -> PBAAClusteringRunRequest {
        try PBAAClusteringRunRequest(
            inputFASTQURL: root.appendingPathComponent("reads.fastq"),
            guideSourceURL: root.appendingPathComponent("guides.fasta"),
            outputDirectory: root.appendingPathComponent("pbaa-output", isDirectory: true),
            outputName: "launch-environment"
        )
    }

    /// The dumped names as a launched process sees them, `__unset__` for a missing one.
    static func dumped(_ environment: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: dumpedNames.map { ($0, environment[$0] ?? unset) })
    }

    static func readDump(_ file: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    static func installScript(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func dumpCommands(to file: URL) -> String {
        let lines = dumpedNames.map { name in #"printf '%s=%s\n' \#(name) "${\#(name)-__unset__}""# }
        return "{\n" + lines.joined(separator: "\n") + "\n} > '\(file.path)'"
    }

    private static func nextflowScript(dump: URL) -> String {
        """
        #!/bin/sh
        \(dumpCommands(to: dump))
        if [ "$1" = "-version" ]; then
          echo "nextflow version \(version)"
          exit 0
        fi
        echo "stub nextflow $*"
        exit 0
        """
    }

    /// Answers `micromamba run -n <env> nextflow ...` the way a finished
    /// TaxTriage run would, with one top report and a trace.
    private static func micromambaScript(dump: URL) -> String {
        #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "micromamba 2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "unexpected micromamba invocation: $*" >&2
          exit 64
        fi
        \#(dumpCommands(to: dump))
        shift
        if [ "$1" = "-n" ]; then
          shift
          shift
        fi
        if [ "$1" != "nextflow" ]; then
          echo "unexpected tool: $1" >&2
          exit 64
        fi
        shift
        outdir=""
        trace=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --outdir)
              shift
              outdir="$1"
              ;;
            -with-trace)
              shift
              trace="$1"
              ;;
          esac
          shift
        done
        if [ -z "$outdir" ]; then
          echo "missing --outdir" >&2
          exit 64
        fi
        mkdir -p "$outdir/top"
        printf 'sample\torganism\nS1\tExample virus\n' > "$outdir/top/S1.top_report.tsv"
        if [ -n "$trace" ]; then
          mkdir -p "$(dirname "$trace")"
          printf 'task_id\tprocess\tstatus\n1\tTAXTRIAGE\tCOMPLETED\n' > "$trace"
        fi
        echo "[aa/000001] Submitted process > TAXTRIAGE (S1)"
        echo "[aa/000001] Completed process > TAXTRIAGE (S1)"
        exit 0
        """#
    }
}

/// A Docker daemon that always answers, so a docker-profile run never starts Docker Desktop.
private struct ReachableDockerProbe: ContainerRuntimeProbing {
    func dockerCLIPath() -> String? { "/usr/local/bin/docker" }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil)
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }
}
