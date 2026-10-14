import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

final class TaxTriageWizardSheetTests: XCTestCase {
    func testStandalonePresentationUsesSharedWizardShellContract() {
        let presentation = TaxTriageStandalonePresentation(
            initialFileCount: 1,
            inputDisplayName: "sample-a",
            sampleCount: 1,
            canRun: false,
            validationMessage: "Checking prerequisites..."
        )

        XCTAssertEqual(presentation.title, "TaxTriage")
        XCTAssertEqual(presentation.subtitle, "End-to-end pathogen detection for metagenomic samples")
        XCTAssertEqual(presentation.accessoryText, "sample-a")
        XCTAssertEqual(presentation.size.width, 520)
        XCTAssertEqual(presentation.size.height, 520)
        XCTAssertEqual(presentation.statusText, "Checking prerequisites...")
        XCTAssertFalse(presentation.isPrimaryEnabled)
    }

    func testStandalonePresentationSummarizesMultipleSamplesWhenReady() {
        let presentation = TaxTriageStandalonePresentation(
            initialFileCount: 2,
            inputDisplayName: "2 FASTQ files",
            sampleCount: 2,
            canRun: true,
            validationMessage: nil
        )

        XCTAssertEqual(presentation.accessoryText, "2 samples")
        XCTAssertNil(presentation.statusText)
        XCTAssertTrue(presentation.isPrimaryEnabled)
    }

    func testAdvancedArgumentsParseErrorDetectsUnterminatedQuote() {
        // Regression test for AS31: performRun() silently no-ops when
        // extraArgumentsText fails to parse, but canRun previously never
        // checked parseability, leaving Run enabled with zero feedback.
        XCTAssertNil(TaxTriageWizardSheet.advancedArgumentsParseError("--flag value"))
        XCTAssertNil(TaxTriageWizardSheet.advancedArgumentsParseError(""))
        XCTAssertNotNil(TaxTriageWizardSheet.advancedArgumentsParseError("--flag 'unterminated"))
    }

    // MARK: - Container prerequisite row

    /// The row follows the Docker daemon verdict shared with
    /// `lungfish-cli debug container`, never the Apple-first runtime factory.
    func testContainerPrerequisiteReportsDockerDaemonRunning() {
        let status = PipelineContainerRuntimeStatus(
            available: true,
            label: "Docker Desktop: Running",
            detail: nil,
            daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
            dockerCLIPath: "/usr/local/bin/docker"
        )
        let row = TaxTriageContainerPrerequisite(status: status)
        XCTAssertTrue(row.available)
        XCTAssertEqual(row.label, "Docker Desktop: Running")
        XCTAssertNil(row.validationMessage)
    }

    func testContainerPrerequisiteReportsDockerDaemonNotRunning() {
        let status = PipelineContainerRuntimeStatus(
            available: false,
            label: "Docker Desktop: Not running",
            detail: "Cannot connect to the Docker daemon",
            daemon: DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: "Cannot connect to the Docker daemon"
            ),
            dockerCLIPath: "/usr/local/bin/docker"
        )
        let row = TaxTriageContainerPrerequisite(status: status)
        XCTAssertFalse(row.available)
        XCTAssertEqual(row.label, "Docker Desktop: Not running")
        XCTAssertEqual(row.validationMessage, "Docker Desktop is not running")
    }

    func testContainerPrerequisiteReportsDockerNotInstalled() {
        let status = PipelineContainerRuntimeStatus(
            available: false,
            label: "Docker Desktop: Not installed",
            detail: "docker CLI not found",
            daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: "docker CLI not found"),
            dockerCLIPath: nil
        )
        let row = TaxTriageContainerPrerequisite(status: status)
        XCTAssertFalse(row.available)
        XCTAssertEqual(row.validationMessage, "Docker Desktop is not installed")
    }

    /// End to end through the shared status: a stub probe whose daemon is
    /// down while Apple Containerization is ready must leave the row red.
    @MainActor
    func testContainerPrerequisiteIgnoresAppleContainerization() async {
        struct DaemonDownAppleReady: ContainerRuntimeProbing {
            func dockerCLIPath() -> String? { "/usr/local/bin/docker" }
            func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
                DockerDaemonProbe(reachable: false, clientVersion: "28.3.2", serverVersion: nil, detail: "daemon down")
            }
            func appleContainerRuntime() async -> AppleContainerProbe {
                AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
            }
        }
        let row = TaxTriageContainerPrerequisite(
            status: await PipelineContainerRuntimeStatus.check(probe: DaemonDownAppleReady())
        )
        XCTAssertFalse(row.available)
        XCTAssertEqual(row.label, "Docker Desktop: Not running")
        // The wizard accepts the same probe so the row can be driven without
        // a Docker install; this pins the initializer signature.
        _ = TaxTriageWizardSheet(containerRuntimeProbe: DaemonDownAppleReady())
    }

    // MARK: - Nextflow prerequisite row

    /// What the wizard's Nextflow row asks, whether Lungfish's managed Nextflow is installed in this tool root. It is
    /// the ask of the preflight of `workflow run`, `WorkflowEngineLaunch.resolveManaged`, and a Nextflow on PATH is
    /// refused. The wizard asks it for the real home, and the three cases below give it a temporary one.
    private func nextflowRowIsAvailable(home: URL) -> Bool {
        (try? WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview)) != nil
    }

    private func installNextflow(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("nextflow")
        try "#!/bin/bash\necho stub nextflow\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func testNextflowRowIsAvailableForTheManagedCopy() throws {
        let home = try TestTempDirectory.make(prefix: "taxtriage-wizard-nextflow")
        defer { TestTempDirectory.cleanup(home) }
        try installNextflow(in: home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true))

        XCTAssertTrue(nextflowRowIsAvailable(home: home))
    }

    func testNextflowRowIsNotAvailableWithoutAManagedCopy() throws {
        let home = try TestTempDirectory.make(prefix: "taxtriage-wizard-nextflow")
        defer { TestTempDirectory.cleanup(home) }

        XCTAssertFalse(nextflowRowIsAvailable(home: home))
    }

    /// A Nextflow on PATH is a different, unpinned version, so it never turns the row green.
    func testNextflowRowIgnoresACopyOnPATH() throws {
        let home = try TestTempDirectory.make(prefix: "taxtriage-wizard-nextflow")
        defer { TestTempDirectory.cleanup(home) }
        let fakeBin = home.appendingPathComponent("fake-bin", isDirectory: true)
        try installNextflow(in: fakeBin)
        let originalPATH = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(fakeBin.path):\(originalPATH ?? "/usr/bin:/bin")", 1)
        defer {
            if let originalPATH {
                setenv("PATH", originalPATH, 1)
            } else {
                unsetenv("PATH")
            }
        }

        XCTAssertFalse(nextflowRowIsAvailable(home: home))
    }
}
