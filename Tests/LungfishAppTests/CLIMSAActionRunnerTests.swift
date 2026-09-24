import XCTest
@testable import LungfishApp
import LungfishKit

final class CLIMSAActionRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testRunStreamsMSAActionEventsIntoOperationCenterAndCompletesWithOutputURL() async throws {
        let tempDir = try makeTemporaryDirectory()
        let output = tempDir.appendingPathComponent("alignment.fasta")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"start","message":"Exporting alignment...","progress":0}'
        printf '%s\\n' '{"event":"progress","progress":0.5,"message":"Writing FASTA..."}'
        printf '%s\\n' '{"event":"log","level":"warning","message":"Annotations are not represented in FASTA."}'
        printf '%s\\n' '{"event":"complete","output":"\(output.path)","outputs":["\(output.path)"]}'
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
        printf '%s\\n' '{"event":"start","message":"Creating bundle...","progress":0}'
        printf '%s\\n' '{"event":"progress","progress":0.5,"message":"Writing bundle..."}'
        printf '%s\\n' '{"event":"complete","output":"\(output.path)","outputs":["\(output.path)"]}'
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
