import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

final class CLINativeBundleImportRunnerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildMSAArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/project/aligned.fasta")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLINativeBundleImportRunner.buildArguments(
            sourceURL: source,
            projectURL: project,
            kind: .msa
        )

        XCTAssertEqual(args, [
            "import", "msa", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testBuildTreeArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/project/tree.nwk")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLINativeBundleImportRunner.buildArguments(
            sourceURL: source,
            projectURL: project,
            kind: .tree
        )

        XCTAssertEqual(args, [
            "import", "tree", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testParseNativeBundleCompleteEvent() throws {
        let json = """
        {"event":"nativeBundleImportComplete","bundle":"/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree","warningCount":2}
        """

        let event = try XCTUnwrap(CLINativeBundleImportRunner.parseEvent(from: json))

        guard case let .complete(bundle, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(bundle, "/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree")
        XCTAssertEqual(warningCount, 2)
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"nativeBundleImportStart","kind":"multiple-sequence-alignment","source":"input.fa"}'
        printf '%s\\n' '{"event":"nativeBundleImportProgress","progress":0.5,"message":"Parsing input.fa"}'
        printf '%s\\n' '{"event":"nativeBundleImportWarning","message":"Duplicate row names are present"}'
        printf '%s\\n' '{"event":"nativeBundleImportComplete","bundle":"\(bundle.path)","warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLINativeBundleImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        // The event glue hops to the main queue; wait for the row to catch up
        // instead of sleeping a fixed 50 ms.
        await waitUntil {
            await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }?.logEntries.contains { $0.message == "Duplicate row names are present" } == true
            }
        }
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Parsing input.fa")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Duplicate row names are present" } == true)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    /// Phase 2.2 lane 5B. The App runners read events through the same
    /// launcher as CLISubprocessTransport, so a JSON event line over the 64 KB
    /// line default arrives whole and decodes. It used to be cut in pieces,
    /// and the run then reported no imported bundle.
    func testACompleteEventLineOver64KBIsDecodedWhole() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        padding=$(/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'p')
        printf '%s%s%s\\n' '{"event":"nativeBundleImportComplete","bundle":"\(bundle.path)","warningCount":3,"padding":"' "$padding" '"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLINativeBundleImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.warningCount, 3)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-native-bundle-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
