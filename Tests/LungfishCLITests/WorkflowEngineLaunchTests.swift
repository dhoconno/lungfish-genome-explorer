import XCTest
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
        let launch = WorkflowEngineLaunch.resolve(executableName: "nextflow", homeDirectory: home)
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
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launch.executableURL.standardizedFileURL.path, managedExecutable.standardizedFileURL.path)
        XCTAssertEqual(launch.argumentPrefix, [])
        XCTAssertNil(launch.environment["NXF_ANSI_LOG"])
        XCTAssertNil(launch.environment["NXF_HOME"])
    }
}
