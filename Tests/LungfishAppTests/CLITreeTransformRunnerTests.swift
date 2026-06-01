import XCTest
@testable import LungfishApp
import LungfishKit

final class CLITreeTransformRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testParseStartEvent() throws {
        let json = #"{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .start(progress, message) = event else {
            return XCTFail("Expected start event, got \(event)")
        }
        XCTAssertEqual(progress, 0)
        XCTAssertEqual(message, "Starting tree transform.")
    }

    func testParseProgressEvent() throws {
        let json = #"{"event":"treeTransformProgress","progress":0.65,"message":"Writing transformed tree bundle."}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .progress(progress, message) = event else {
            return XCTFail("Expected progress event, got \(event)")
        }
        XCTAssertEqual(progress, 0.65, accuracy: 0.0001)
        XCTAssertEqual(message, "Writing transformed tree bundle.")
    }

    func testParseCompleteEvent() throws {
        let json = #"{"event":"treeTransformComplete","progress":1,"output":"/project/Phylogenetic Trees/example-rerooted.lungfishtree"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .complete(output) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(output, "/project/Phylogenetic Trees/example-rerooted.lungfishtree")
    }

    func testParseFailedEvent() throws {
        let json = #"{"event":"treeTransformFailed","error":"node not found: ABC"}"#
        let event = try XCTUnwrap(CLITreeTransformRunner.parseEvent(from: json))
        guard case let .failed(error) = event else {
            return XCTFail("Expected failed event, got \(event)")
        }
        XCTAssertEqual(error, "node not found: ABC")
    }

    func testParseIgnoresNonJSONAndUnknownEvents() throws {
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: "Wrote tree bundle: /path"))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: ""))
        XCTAssertNil(try CLITreeTransformRunner.parseEvent(from: #"{"event":"somethingElse"}"#))
    }

    func testRunStreamsTreeTransformEventsIntoOperationCenterAndCompletesWithBundleURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("example-rerooted.lungfishtree", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}'
        printf '%s\\n' '{"event":"treeTransformProgress","progress":0.65,"message":"Writing transformed tree bundle."}'
        printf '%s\\n' '{"event":"treeTransformComplete","progress":1,"output":"\(output.path)"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let readyBundles = ReadyBundleCapture()
        let opID = await MainActor.run {
            OperationCenter.shared.onBundleReady = { readyBundles.set($0) }
            return OperationCenter.shared.start(
                title: "Re-root Tree",
                detail: "Launching...",
                operationType: .phylogeneticTreeTransform
            )
        }

        let result = try await CLITreeTransformRunner(cliURLOverride: fakeCLI)
            .run(arguments: ["tree", "reroot"], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, output.path)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress, 1.0)
        XCTAssertEqual(item?.detail, "Tree transform complete")
        XCTAssertEqual(item?.bundleURLs.map(\.path), [output.path])
        XCTAssertEqual(readyBundles.paths(), [output.path])
        XCTAssertTrue(item?.logEntries.contains { $0.level == .info && $0.message.contains("Starting tree transform") } == true)
        await MainActor.run {
            OperationCenter.shared.onBundleReady = nil
        }
    }

    func testRunFailsOperationOnFailedEvent() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"treeTransformStart","progress":0,"message":"Starting tree transform."}'
        printf '%s\\n' '{"event":"treeTransformFailed","error":"node not found: ABC"}'
        exit 1
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "Re-root Tree",
                detail: "Launching...",
                operationType: .phylogeneticTreeTransform
            )
        }

        do {
            _ = try await CLITreeTransformRunner(cliURLOverride: fakeCLI)
                .run(arguments: ["tree", "reroot"], operationID: opID)
            XCTFail("Expected run to throw")
        } catch {
            // expected
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }
        XCTAssertEqual(item?.state, .failed)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-tree-transform-runner-\(UUID().uuidString)", isDirectory: true)
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
