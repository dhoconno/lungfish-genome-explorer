// WorkflowTemplateCommandTests.swift - CLI tests for `workflow template`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class WorkflowTemplateCommandTests: XCTestCase {

    private var savedResolver: AnalysisTemplateRunner.DatabaseResolver!
    private var savedExecutorFactory: (@Sendable (ProcessAnalysisTemplateStepExecutor.OutputHandler?) -> any AnalysisTemplateStepExecuting)!

    override func setUp() {
        super.setUp()
        savedResolver = WorkflowTemplateRunSubcommand.databaseResolver
        savedExecutorFactory = WorkflowTemplateRunSubcommand.stepExecutorFactory
        WorkflowTemplateRunSubcommand.databaseResolver = { _ in
            AnalysisTemplateDatabaseStatus(isReady: true, version: "20260626", digest: nil, path: URL(fileURLWithPath: "/dbs/viral"))
        }
    }

    override func tearDown() {
        WorkflowTemplateRunSubcommand.databaseResolver = savedResolver
        WorkflowTemplateRunSubcommand.stepExecutorFactory = savedExecutorFactory
        super.tearDown()
    }

    // MARK: - Parsing

    func testTemplateGroupParsesThroughTopLevelWorkflowCommand() throws {
        let subcommands = WorkflowCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommands.contains("template"))
        let templateSubcommands = WorkflowTemplateCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(templateSubcommands, ["create", "list", "show", "run"])

        let create = try WorkflowTemplateCreateSubcommand.parse([
            "--from", "/p/Analyses/kraken2-x", "--name", "My Template", "--output", "/tmp/t.lungfishtemplate", "--format", "json",
        ])
        XCTAssertEqual(create.from, "/p/Analyses/kraken2-x")
        XCTAssertEqual(create.name, "My Template")
        XCTAssertEqual(create.output, "/tmp/t.lungfishtemplate")
        XCTAssertEqual(create.format, .json)

        let list = try WorkflowTemplateListSubcommand.parse(["--library", "/tmp/lib", "--format", "json"])
        XCTAssertEqual(list.libraryOption.library, "/tmp/lib")

        let show = try WorkflowTemplateShowSubcommand.parse(["My Template", "--format", "shell"])
        XCTAssertEqual(show.template, "My Template")
        XCTAssertEqual(show.format, .shell)

        let run = try WorkflowTemplateRunSubcommand.parse([
            "/tmp/t.lungfishtemplate", "--project", "/p.lungfish", "/r/a_R1.fastq.gz", "/r/a_R2.fastq.gz",
            "--name", "S9", "--threads", "5", "--dry-run", "--allow-drift",
        ])
        XCTAssertEqual(run.template, "/tmp/t.lungfishtemplate")
        XCTAssertEqual(run.project, "/p.lungfish")
        XCTAssertEqual(run.inputs, ["/r/a_R1.fastq.gz", "/r/a_R2.fastq.gz"])
        XCTAssertEqual(run.name, "S9")
        XCTAssertEqual(run.globalOptions.threads, 5)
        XCTAssertTrue(run.dryRun)
        XCTAssertTrue(run.allowDrift)
    }

    // MARK: - create / show / list

    func testCreateWritesTemplateToOutputAndShowRendersShell() async throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }
        let output = fixture.rootURL.appendingPathComponent("out/My.lungfishtemplate")

        let create = try WorkflowTemplateCreateSubcommand.parse([
            "--from", fixture.analysisURL.path, "--output", output.path, "--format", "json",
        ])
        let createOutput = try await captureStandardOutput { try await create.run() }
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(createOutput.utf8)) as? [String: Any])
        XCTAssertEqual(created["file"] as? String, output.path)
        XCTAssertEqual(created["sourceBundle"] as? String, fixture.bundleURL.path)
        let template = try AnalysisTemplate.load(from: output)
        XCTAssertEqual(template.name, "Kraken2 + Bracken from SRRTEST1")
        XCTAssertEqual(template.kraken2Step?.database.name, "Viral")

        let show = try WorkflowTemplateShowSubcommand.parse([output.path, "--format", "shell"])
        let script = try await captureStandardOutput { try await show.run() }
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n# Workflow template: Kraken2 + Bracken from SRRTEST1"))
        XCTAssertTrue(script.contains("lungfish-cli import fastq '<reads_R1.fastq.gz>' '<reads_R2.fastq.gz>'"))
        XCTAssertTrue(script.contains("--pairing paired"))
        XCTAssertTrue(script.contains("--name '<sample>'"))
        XCTAssertTrue(script.contains("lungfish-cli conda classify --db Viral"))
        XCTAssertTrue(script.contains("--profile"))
        XCTAssertFalse(script.contains(fixture.rootURL.path), "shell export must not carry the source project path")

        let showText = try WorkflowTemplateShowSubcommand.parse([output.path])
        let text = try await captureStandardOutput { try await showText.run() }
        XCTAssertTrue(text.contains("Input: Paired Illumina FASTQ files"))
        XCTAssertTrue(text.contains("1. Import FASTQ"))
        XCTAssertTrue(text.contains("2. Kraken2 + Bracken"))
        XCTAssertTrue(text.contains("Fixed resource: Kraken2 database Viral (20260626)"))
    }

    func testCreateIntoLibraryAndList() async throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }
        let library = fixture.rootURL.appendingPathComponent("Library")

        let create = try WorkflowTemplateCreateSubcommand.parse([
            "--from", fixture.analysisURL.path, "--library", library.path, "--name", "Viral screen",
        ])
        let createText = try await captureStandardOutput { try await create.run() }
        XCTAssertTrue(createText.contains("Saved workflow template \"Viral screen\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Viral screen.lungfishtemplate").path))

        let list = try WorkflowTemplateListSubcommand.parse(["--library", library.path, "--format", "json"])
        let listOutput = try await captureStandardOutput { try await list.run() }
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listOutput.utf8)) as? [String: Any])
        let templates = try XCTUnwrap(listed["templates"] as? [[String: Any]])
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates[0]["name"] as? String, "Viral screen")

        let listText = try WorkflowTemplateListSubcommand.parse(["--library", library.path])
        let text = try await captureStandardOutput { try await listText.run() }
        XCTAssertTrue(text.contains("Viral screen"))
        XCTAssertTrue(text.contains("Import FASTQ and apply recipe VSP2 Target Enrichment → Kraken2 + Bracken"))

        // The library name resolves for show.
        let show = try WorkflowTemplateShowSubcommand.parse(["viral screen", "--library", library.path, "--format", "json"])
        let json = try await captureStandardOutput { try await show.run() }
        XCTAssertEqual(try AnalysisTemplate.load(from: Data(json.utf8)).name, "Viral screen")
    }

    func testCreateRefusalIsATypedValidationError() async throws {
        var options = AnalysisTemplateTestFixture.ClassificationOptions()
        options.includeOriginalInputFiles = false
        let fixture = try AnalysisTemplateTestFixture.make(classification: options)
        defer { fixture.cleanup() }

        let create = try WorkflowTemplateCreateSubcommand.parse(["--from", fixture.analysisURL.path, "--output", fixture.rootURL.appendingPathComponent("x.lungfishtemplate").path])
        do {
            try await create.run()
            XCTFail("expected refusal")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].contains("does not name its original input files"))
        }
    }

    // MARK: - run --dry-run

    func testRunDryRunPrintsStepsAndReadiness() async throws {
        // No recipe, so readiness depends only on the (stubbed) database lookup.
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.recipe = "none"
        importOptions.recipeApplied = nil
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }
        let templateURL = fixture.rootURL.appendingPathComponent("t.lungfishtemplate")
        let create = try WorkflowTemplateCreateSubcommand.parse(["--from", fixture.analysisURL.path, "--output", templateURL.path])
        _ = try await captureStandardOutput { try await create.run() }

        let r1 = fixture.rootURL.appendingPathComponent("new_R1.fastq")
        let r2 = fixture.rootURL.appendingPathComponent("new_R2.fastq")
        try Data("@a/1\nACGT\n+\n!!!!\n".utf8).write(to: r1)
        try Data("@a/2\nACGT\n+\n!!!!\n".utf8).write(to: r2)
        let targetProject = fixture.rootURL.appendingPathComponent("Target.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: targetProject, withIntermediateDirectories: true)

        let dryRun = try WorkflowTemplateRunSubcommand.parse([
            templateURL.path, "--project", targetProject.path, r1.path, r2.path, "--dry-run", "--format", "json", "--threads", "2",
        ])
        let output = try await captureStandardOutput { try await dryRun.run() }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["dryRun"] as? Bool, true)
        XCTAssertEqual(json["runnable"] as? Bool, true)
        XCTAssertEqual(json["templateFile"] as? String, templateURL.path)
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["kind"] as? String }, ["importFASTQ", "kraken2"])
        let importArguments = try XCTUnwrap(steps[0]["arguments"] as? [String])
        XCTAssertEqual(Array(importArguments.prefix(4)), ["import", "fastq", r1.path, r2.path])
        XCTAssertEqual(importArguments[importArguments.firstIndex(of: "--pairing")! + 1], "paired")
        XCTAssertEqual(importArguments[importArguments.firstIndex(of: "--name")! + 1], "new")
        XCTAssertFalse(importArguments.contains("--recipe"))
        let classifyArguments = try XCTUnwrap(steps[1]["arguments"] as? [String])
        XCTAssertEqual(classifyArguments.last, targetProject.appendingPathComponent("Imports/new.lungfishfastq").path)
        XCTAssertEqual(classifyArguments[classifyArguments.firstIndex(of: "--threads")! + 1], "2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("Analyses").path), "dry run must not touch the project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("Imports").path))

        let text = try WorkflowTemplateRunSubcommand.parse([
            templateURL.path, "--project", targetProject.path, r1.path, r2.path, "--dry-run",
        ])
        let textOutput = try await captureStandardOutput { try await text.run() }
        XCTAssertTrue(textOutput.contains("Step 1: Import FASTQ"))
        XCTAssertTrue(textOutput.contains("Step 2: Kraken2 + Bracken"))
        XCTAssertTrue(textOutput.contains("lungfish-cli conda classify --db Viral"))
        XCTAssertTrue(textOutput.contains("Ready"))
    }

    func testRunDryRunRefusesWithWrongInputCount() async throws {
        var importOptions = AnalysisTemplateTestFixture.ImportOptions()
        importOptions.recipe = "none"
        importOptions.recipeApplied = nil
        let fixture = try AnalysisTemplateTestFixture.make(importOptions: importOptions)
        defer { fixture.cleanup() }
        let templateURL = fixture.rootURL.appendingPathComponent("t.lungfishtemplate")
        let create = try WorkflowTemplateCreateSubcommand.parse(["--from", fixture.analysisURL.path, "--output", templateURL.path])
        _ = try await captureStandardOutput { try await create.run() }
        let r1 = fixture.rootURL.appendingPathComponent("only.fastq")
        try Data("@a\nACGT\n+\n!!!!\n".utf8).write(to: r1)

        let run = try WorkflowTemplateRunSubcommand.parse([templateURL.path, "--project", fixture.projectURL.path, r1.path, "--dry-run"])
        do {
            _ = try await captureStandardOutput { try await run.run() }
            XCTFail("expected refusal")
        } catch let error as CLIError {
            guard case .validationFailed(let errors) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(errors[0].contains("expects 2 FASTQ files per run but 1 were given"))
        }
    }

    func testRunRefusesWhenDatabaseIsMissing() async throws {
        let fixture = try AnalysisTemplateTestFixture.make()
        defer { fixture.cleanup() }
        let templateURL = fixture.rootURL.appendingPathComponent("t.lungfishtemplate")
        let create = try WorkflowTemplateCreateSubcommand.parse(["--from", fixture.analysisURL.path, "--output", templateURL.path])
        _ = try await captureStandardOutput { try await create.run() }
        WorkflowTemplateRunSubcommand.databaseResolver = { _ in nil }

        let r1 = fixture.rootURL.appendingPathComponent("s_R1.fastq")
        let r2 = fixture.rootURL.appendingPathComponent("s_R2.fastq")
        try Data("@a/1\nACGT\n+\n!!!!\n".utf8).write(to: r1)
        try Data("@a/2\nACGT\n+\n!!!!\n".utf8).write(to: r2)
        let run = try WorkflowTemplateRunSubcommand.parse([
            templateURL.path, "--project", fixture.projectURL.path, r1.path, r2.path, "--dry-run",
        ])
        let output: String
        do {
            output = try await captureStandardOutput { try await run.run() }
            XCTFail("expected refusal, got: \(output)")
        } catch {
            XCTAssertEqual((error as? ExitCode)?.rawValue, CLIExitCode.dependency.exitCode.rawValue)
        }
    }

    // MARK: - Helpers

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
