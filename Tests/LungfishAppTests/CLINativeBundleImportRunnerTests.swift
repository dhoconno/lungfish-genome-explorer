import XCTest
@testable import LungfishApp

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
            OperationCenter.shared.start(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport
            )
        }

        let result = try await CLINativeBundleImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Parsing input.fa")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Duplicate row names are present" } == true)
        await MainActor.run {
            OperationCenter.shared.complete(id: opID, detail: "Test complete")
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
