import XCTest
@testable import LungfishApp

final class CLIMSAActionRunnerTests: XCTestCase {
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
        {"event":"msaActionComplete","actionID":"msa.export.fasta","operationID":"op-123","output":"/project/alignment.fasta","warningCount":2}
        """

        let event = try XCTUnwrap(CLIMSAActionRunner.parseEvent(from: json))

        guard case let .complete(actionID, operationID, output, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(actionID, "msa.export.fasta")
        XCTAssertEqual(operationID, "op-123")
        XCTAssertEqual(output, "/project/alignment.fasta")
        XCTAssertEqual(warningCount, 2)
    }

    func testRunStreamsMSAActionEventsIntoOperationCenterAndCompletesWithOutputURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("alignment.fasta")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"msaActionStart","actionID":"msa.export.fasta","operationID":"op-123","progress":0,"message":"Exporting alignment..."}'
        printf '%s\\n' '{"event":"msaActionProgress","actionID":"msa.export.fasta","operationID":"op-123","progress":0.5,"message":"Writing FASTA..."}'
        printf '%s\\n' '{"event":"msaActionWarning","actionID":"msa.export.fasta","operationID":"op-123","message":"Annotations are not represented in FASTA.","warningCount":1}'
        printf '%s\\n' '{"event":"msaActionComplete","actionID":"msa.export.fasta","operationID":"op-123","output":"\(output.path)","warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "Export Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentAction
            )
        }

        let result = try await CLIMSAActionRunner(cliURLOverride: fakeCLI)
            .run(arguments: ["msa", "export"], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.outputURL.path, output.path)
        XCTAssertEqual(result.actionID, "msa.export.fasta")
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.progress, 1.0)
        XCTAssertEqual(item?.detail, "MSA action complete")
        XCTAssertEqual(item?.outputURLs.map(\.path), [output.path])
        XCTAssertEqual(item?.bundleURLs, [])
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Annotations are not represented in FASTA." } == true)
    }

    func testRunCompletesNativeBundleOutputWithBundleURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("selected.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"msaActionStart","actionID":"msa.export.fasta","operationID":"op-456","progress":0,"message":"Creating bundle..."}'
        printf '%s\\n' '{"event":"msaActionProgress","actionID":"msa.export.fasta","operationID":"op-456","progress":0.5,"message":"Writing bundle..."}'
        printf '%s\\n' '{"event":"msaActionComplete","actionID":"msa.export.fasta","operationID":"op-456","output":"\(output.path)","warningCount":0}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let readyBundleRecorder = URLListRecorder()
        await MainActor.run {
            OperationCenter.shared.onBundleReady = { readyBundleRecorder.record($0) }
        }

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "Create MSA Selection Bundle",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentAction
            )
        }

        let result = try await CLIMSAActionRunner(cliURLOverride: fakeCLI)
            .run(arguments: ["msa", "extract"], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }
        await MainActor.run {
            OperationCenter.shared.onBundleReady = nil
        }

        XCTAssertEqual(result.outputURL.path, output.path)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.bundleURLs.map(\.path), [output.path])
        XCTAssertEqual(item?.outputURLs, [])
        XCTAssertEqual(readyBundleRecorder.urls.map(\.path), [output.path])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-msa-action-runner-\(UUID().uuidString)", isDirectory: true)
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

private final class URLListRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ urls: [URL]) {
        lock.lock()
        storage = urls
        lock.unlock()
    }
}
