// FASTQLinuxRunOperationTests.swift - The Operations rows of the adopt of a Linux run and of the plan sheet (C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// ARCH 2: each row's command is the argv the run executes, and the adopt's is the envelope's argv.
@MainActor
final class FASTQLinuxRunOperationTests: XCTestCase {
    func testAdoptRowRecordsTheCommandTheCLIRuns() throws {
        let folder = URL(fileURLWithPath: "/data/returned/S1", isDirectory: true)
        let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
        var launched: (id: UUID, arguments: [String])?
        let result = FASTQIngestionService.beginLinuxRunAdoptOperation(
            resultFolder: folder, projectDirectory: project, routeContext: nil
        ) { launched = ($0, $1) }
        guard case .started(let id) = result else { return XCTFail("the adopt row did not start") }
        defer { _ = OperationCenter.shared.fail(id: id, detail: "test", errorMessage: "test") }
        let run = try XCTUnwrap(launched)
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(
            run.arguments,
            ExecutorRunAdoption.cliArguments(resultFolder: folder, projectDirectory: project, eventsOn: true),
            "the run is the adopt's own argv, which the envelope records after the executable"
        )
        XCTAssertEqual(
            run.arguments,
            ["import", "fastq", "/data/returned/S1", "--adopt", "--project", "/data/Project.lungfish", "--format", "json"]
        )
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: run.arguments))
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.title, "Linux Run Result: S1")
        // beginLinuxRunAdoptOperation's row parses as the CLI's own command, the one the adopt runs.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertTrue(command.adoptOptions.adopt)
        XCTAssertEqual(command.input, [folder.path])
        XCTAssertEqual(command.project, project.path)
        XCTAssertNil(command.adoptRefusal)
    }

    func testPlanRowRecordsTheCommandTheSheetRuns() throws {
        let arguments = FASTQPlanSheetModel.cliArguments(
            inputs: [URL(fileURLWithPath: "/data/reads")], planFolder: URL(fileURLWithPath: "/data/plan-1"),
            executorManifest: URL(fileURLWithPath: "/app/LinuxExecutor/x86_64/manifest.json"),
            image: URL(fileURLWithPath: "/app/image.json"), imageToolManifest: URL(fileURLWithPath: "/app/image-manifest.json"),
            stagingFolder: "/staging/groups/g/1/lge", threads: 8, clumpifyHeapGB: 16, optimizeStorage: true, tool: .bbtools
        )
        let request = FASTQPlanSheetRequest(arguments: arguments, planFolder: URL(fileURLWithPath: "/data/plan-1"))
        var launched: [String]?
        let result = FASTQIngestionService.beginLinuxPlanOperation(request: request, routeContext: nil) { launched = $1 }
        guard case .started(let id) = result else { return XCTFail("the plan row did not start") }
        defer { _ = OperationCenter.shared.fail(id: id, detail: "test", errorMessage: "test") }
        XCTAssertEqual(launched, arguments)
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: arguments))
        XCTAssertEqual(item.title, "Plan for a Linux Machine: plan-1")
        // beginLinuxPlanOperation's row parses as the CLI's own `import fastq --write-plan`.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(command.planOptions.writePlan, "/data/plan-1")
        XCTAssertEqual(command.planOptions.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(command.importOptions.clumpingTool, "bbtools")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.clumpifyHeapGB, 16)
    }
}
