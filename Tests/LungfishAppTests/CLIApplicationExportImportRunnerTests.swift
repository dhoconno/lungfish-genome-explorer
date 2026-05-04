import XCTest
@testable import LungfishApp

final class CLIApplicationExportImportRunnerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildApplicationExportArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/tmp/CLC Export.zip")
        let project = URL(fileURLWithPath: "/tmp/Project.lungfish")

        let args = CLIApplicationExportImportRunner.buildApplicationExportArguments(
            sourceURL: source,
            projectURL: project,
            kind: .clcWorkbench
        )

        XCTAssertEqual(args, [
            "import", "application-export", "clc-workbench", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testBuildGeneiousArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/tmp/MCM_MHC_haplotypes-annotated.geneious")
        let project = URL(fileURLWithPath: "/tmp/Project.lungfish")

        let args = CLIApplicationExportImportRunner.buildGeneiousArguments(
            sourceURL: source,
            projectURL: project
        )

        XCTAssertEqual(args, [
            "import", "geneious", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testParseApplicationExportProgressEvent() throws {
        let json = """
        {"event":"applicationExportProgress","progress":0.42,"message":"Processing refs/reference.fa"}
        """

        let event = try XCTUnwrap(CLIApplicationExportImportRunner.parseEvent(from: json))

        guard case let .progress(progress, message) = event else {
            return XCTFail("Expected progress event, got \(event)")
        }
        XCTAssertEqual(progress, 0.42, accuracy: 0.0001)
        XCTAssertEqual(message, "Processing refs/reference.fa")
    }

    func testParseApplicationExportCompleteEvent() throws {
        let json = """
        {"event":"applicationExportImportComplete","collection":"/tmp/Project.lungfish/Application Exports/Example CLC Workbench Import","warningCount":2}
        """

        let event = try XCTUnwrap(CLIApplicationExportImportRunner.parseEvent(from: json))

        guard case let .complete(collection, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(collection, "/tmp/Project.lungfish/Application Exports/Example CLC Workbench Import")
        XCTAssertEqual(warningCount, 2)
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let collection = tempDir.appendingPathComponent("Imported Collection", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/tmp/source.zip"}'
        printf '%s\\n' '{"event":"applicationExportProgress","progress":0.5,"message":"Processing refs/reference.fa"}'
        printf '%s\\n' '{"event":"applicationExportWarning","message":"reports/summary.tsv was preserved"}'
        printf '%s\\n' '{"event":"applicationExportImportComplete","collection":"\(collection.path)","warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "CLC Workbench Import",
                detail: "Launching...",
                operationType: .applicationExportImport
            )
        }

        let result = try await CLIApplicationExportImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.collectionURL.path, collection.path)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Processing refs/reference.fa")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "reports/summary.tsv was preserved" } == true)
        await MainActor.run {
            OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-application-export-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
