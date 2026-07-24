import XCTest
@testable import LungfishApp
import LungfishKit

final class CLIEventRunnerCancellationTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testMSAActionRunnerCancelReturnsBeforeSleepingCLIExits() async throws {
        let fakeCLI = try makeSleepingCLI(directoryPrefix: "cli-msa-action-cancel")
        let runner = CLIMSAActionRunner(cliURLOverride: fakeCLI.executable)
        let operationID = await startOperation(type: .multipleSequenceAlignmentAction)
        let runTask = Task {
            try await runner.run(arguments: ["msa", "export"], operationID: operationID)
        }

        try await waitUntilFileExists(fakeCLI.startedMarker)
        let elapsed = elapsedSeconds {
            runner.cancel()
        }
        await ignoreRunResult(runTask)
        await clearOperation(operationID)

        XCTAssertLessThan(elapsed, 0.1, "Cancellation requests should return without walking the process tree inline")
    }

    func testTreeInferenceRunnerCancelReturnsBeforeSleepingCLIExits() async throws {
        let fakeCLI = try makeSleepingCLI(directoryPrefix: "cli-tree-inference-cancel")
        let runner = CLITreeInferenceRunner(cliURLOverride: fakeCLI.executable)
        let operationID = await startOperation(type: .phylogeneticTreeInference)
        let runTask = Task {
            try await runner.run(arguments: ["tree", "infer"], operationID: operationID)
        }

        try await waitUntilFileExists(fakeCLI.startedMarker)
        let elapsed = elapsedSeconds {
            runner.cancel()
        }
        await ignoreRunResult(runTask)
        await clearOperation(operationID)

        XCTAssertLessThan(elapsed, 0.1, "Cancellation requests should return without walking the process tree inline")
    }

    func testTreeTransformRunnerCancelReturnsBeforeSleepingCLIExits() async throws {
        let fakeCLI = try makeSleepingCLI(directoryPrefix: "cli-tree-transform-cancel")
        let runner = CLITreeTransformRunner(cliURLOverride: fakeCLI.executable)
        let operationID = await startOperation(type: .phylogeneticTreeTransform)
        let runTask = Task {
            try await runner.run(arguments: ["tree", "reroot"], operationID: operationID)
        }

        try await waitUntilFileExists(fakeCLI.startedMarker)
        let elapsed = elapsedSeconds {
            runner.cancel()
        }
        await ignoreRunResult(runTask)
        await clearOperation(operationID)

        XCTAssertLessThan(elapsed, 0.1, "Cancellation requests should return without walking the process tree inline")
    }

    private func makeSleepingCLI(directoryPrefix: String) throws -> (executable: URL, startedMarker: URL) {
        let directory = try makeTemporaryDirectory(prefix: directoryPrefix)
        let executable = directory.appendingPathComponent("lungfish-cli")
        let startedMarker = directory.appendingPathComponent("started")
        let script = """
        #!/bin/sh
        touch "\(startedMarker.path)"
        sleep 2
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, startedMarker)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanupURLs.append(url)
        return url
    }

    private func waitUntilFileExists(_ url: URL, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }

    private func elapsedSeconds(_ operation: () -> Void) -> TimeInterval {
        let clock = ContinuousClock()
        let start = clock.now
        operation()
        let components = start.duration(to: clock.now).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func startOperation(type: OperationType) async -> UUID {
        await MainActor.run {
            OperationCenter.shared.start(
                title: "Cancellation Test",
                detail: "Launching...",
                operationType: type
            )
        }
    }

    private func ignoreRunResult<T>(_ task: Task<T, Error>) async {
        _ = try? await task.value
    }

    private func clearOperation(_ id: UUID) async {
        await MainActor.run {
            OperationCenter.shared.clearItem(id: id)
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
