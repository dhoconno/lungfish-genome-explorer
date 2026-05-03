import XCTest
@testable import LungfishApp

final class CLITreeInferenceRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testParseCompleteEvent() throws {
        let json = """
        {"event":"treeInferenceComplete","output":"/project/Phylogenetic Trees/example.lungfishtree","progress":1}
        """

        let event = try XCTUnwrap(CLITreeInferenceRunner.parseEvent(from: json))

        guard case let .complete(output) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(output, "/project/Phylogenetic Trees/example.lungfishtree")
    }

    func testRunStreamsTreeInferenceEventsIntoOperationCenterAndCompletesWithBundleURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("example.lungfishtree", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"treeInferenceStart","progress":0,"message":"Starting IQ-TREE inference."}'
        printf '%s\\n' '{"event":"treeInferenceProgress","progress":0.5,"message":"Running IQ-TREE."}'
        printf '%s\\n' '{"event":"treeInferenceComplete","progress":1,"output":"\(output.path)"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let readyBundles = ReadyBundleCapture()
        let opID = await MainActor.run {
            OperationCenter.shared.onBundleReady = { readyBundles.set($0) }
            return OperationCenter.shared.start(
                title: "Build Tree",
                detail: "Launching...",
                operationType: .phylogeneticTreeInference
            )
        }

        let result = try await CLITreeInferenceRunner(cliURLOverride: fakeCLI)
            .run(arguments: ["tree", "infer", "iqtree"], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, output.path)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress, 1.0)
        XCTAssertEqual(item?.detail, "Tree inference complete")
        XCTAssertEqual(item?.bundleURLs.map(\.path), [output.path])
        XCTAssertEqual(readyBundles.paths(), [output.path])
        XCTAssertTrue(item?.logEntries.contains { $0.level == .info && $0.message.contains("Starting IQ-TREE") } == true)
        await MainActor.run {
            OperationCenter.shared.onBundleReady = nil
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-tree-inference-runner-\(UUID().uuidString)", isDirectory: true)
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
