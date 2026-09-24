import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishWorkflow

/// Replaces `CLITreeInferenceRunnerTests` and `CLITreeTransformRunnerTests`,
/// which duplicated the same fixture and assertions against two
/// near-identical runners (ARC-02, SIMP-04). `CLITreeRunner` now backs both
/// "tree infer" and "tree transform" launch sites, so one parameterized suite
/// covers both labels against the shared `CLIEvent` wire schema.
final class CLITreeRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    private struct Fixture {
        let label: String
        let operationType: OperationType
        let arguments: [String]
    }

    private let fixtures: [Fixture] = [
        Fixture(label: "tree inference", operationType: .phylogeneticTreeInference, arguments: ["tree", "infer", "iqtree"]),
        Fixture(label: "tree transform", operationType: .phylogeneticTreeTransform, arguments: ["tree", "reroot"]),
    ]

    func testRunStreamsCLIEventsIntoOperationCenterAndCompletesWithBundleURLForEachLabel() async throws {
        for fixture in fixtures {
            let tempDir = try makeTemporaryDirectory()
            let output = tempDir.appendingPathComponent("example.lungfishtree", isDirectory: true)
            let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
            let script = """
            #!/bin/sh
            printf '%s\\n' '{"event":"start","progress":0,"message":"Starting \(fixture.label)."}'
            printf '%s\\n' '{"event":"progress","progress":0.5,"message":"Running \(fixture.label)."}'
            printf '%s\\n' '{"event":"complete","progress":1,"outputs":["\(output.path)"],"output":"\(output.path)"}'
            """
            try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

            let readyBundles = ReadyBundleCapture()
            let opID = await MainActor.run {
                OperationCenter.shared.onBundleReady = { readyBundles.set($0) }
                return OperationCenter.shared.start(
                    title: "Run \(fixture.label)",
                    detail: "Launching...",
                    operationType: fixture.operationType
                )
            }

            let result = try await CLITreeRunner(label: fixture.label, cliURLOverride: fakeCLI)
                .run(arguments: fixture.arguments, operationID: opID)

            try await Task.sleep(nanoseconds: 50_000_000)
            let item = await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }
            }

            XCTAssertEqual(result.bundleURL.path, output.path, "label: \(fixture.label)")
            XCTAssertEqual(item?.state, .completed, "label: \(fixture.label)")
            XCTAssertEqual(item?.progress, 1.0, "label: \(fixture.label)")
            XCTAssertEqual(item?.bundleURLs.map(\.path), [output.path], "label: \(fixture.label)")
            XCTAssertEqual(readyBundles.paths(), [output.path], "label: \(fixture.label)")
            XCTAssertTrue(
                item?.logEntries.contains { $0.level == .info && $0.message.contains("Starting \(fixture.label)") } == true,
                "label: \(fixture.label)"
            )
            await MainActor.run {
                OperationCenter.shared.onBundleReady = nil
                OperationCenter.shared.clearItem(id: opID)
            }
        }
    }

    func testRunFailsOperationOnFailedEventForEachLabel() async throws {
        for fixture in fixtures {
            let tempDir = try makeTemporaryDirectory()
            let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
            let script = """
            #!/bin/sh
            printf '%s\\n' '{"event":"start","progress":0,"message":"Starting \(fixture.label)."}'
            printf '%s\\n' '{"event":"failed","error":"node not found: ABC"}'
            exit 1
            """
            try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

            let opID = await MainActor.run {
                OperationCenter.shared.start(
                    title: "Run \(fixture.label)",
                    detail: "Launching...",
                    operationType: fixture.operationType
                )
            }

            do {
                _ = try await CLITreeRunner(label: fixture.label, cliURLOverride: fakeCLI)
                    .run(arguments: fixture.arguments, operationID: opID)
                XCTFail("Expected run to throw for label \(fixture.label)")
            } catch {
                // expected
            }

            try await Task.sleep(nanoseconds: 50_000_000)
            let item = await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }
            }
            XCTAssertEqual(item?.state, .failed, "label: \(fixture.label)")
            await MainActor.run {
                OperationCenter.shared.clearItem(id: opID)
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-tree-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanupURLs.append(url)
        return url
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class ReadyBundleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func set(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        storage = urls
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.path)
    }
}
