// WorkflowBuilderNativeRunnerTests.swift - Native Workflow Builder FASTQ runner tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class WorkflowBuilderNativeRunnerTests: XCTestCase {
    func testRunnerExecutesCompiledVSP2PlanAndWritesOutputBundleProvenance() async throws {
        let fixture = try makePairedProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000601", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor()
        let runner = WorkflowBuilderNativeRunner(recipeExecutor: executor)

        let result = try await runner.run(
            graph: graph,
            projectURL: fixture.projectURL,
            runDirectoryURL: runDirectory,
            workflowBundleURL: fixture.workflowBundleURL,
            argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
            threads: 2
        )

        XCTAssertEqual(executor.invocations.count, 1)
        XCTAssertEqual(executor.invocations[0].recipe.steps.map(\.type), [
            "fastp-dedup",
            "fastp-trim",
            "deacon-scrub",
            "fastp-merge",
            "seqkit-length-filter",
        ])
        XCTAssertEqual(executor.invocations[0].input.format, .pairedR1R2)
        XCTAssertEqual(executor.invocations[0].input.r1.lastPathComponent, "Sample_R1.fastq")
        XCTAssertEqual(executor.invocations[0].input.r2?.lastPathComponent, "Sample_R2.fastq")

        XCTAssertTrue(FASTQBundle.isBundleURL(result.outputBundleURL))
        XCTAssertTrue(result.outputFASTQURL.path.hasPrefix(result.outputBundleURL.path))
        XCTAssertEqual(try String(contentsOf: result.outputFASTQURL, encoding: .utf8), FakeWorkflowBuilderRecipeExecutor.outputFASTQ)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.planURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: result.outputBundleURL))
        XCTAssertEqual(manifest.name, result.outputBundleURL.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(manifest.parentBundleRelativePath, "@/Imports/Sample.lungfishfastq")
        XCTAssertEqual(manifest.rootBundleRelativePath, "@/Imports/Sample.lungfishfastq")
        XCTAssertEqual(manifest.rootFASTQFilename, "Sample_R1.fastq")
        let expectedLineage: [FASTQDerivativeOperationKind] = [
            .deduplicate,
            .fastpTrim,
            .humanReadScrub,
            .pairedEndMerge,
            .lengthFilter,
        ]
        XCTAssertEqual(manifest.lineage.map(\.kind), expectedLineage)
        XCTAssertEqual(manifest.operation.kind, .lengthFilter)
        XCTAssertTrue(manifest.isMaterialized)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: result.provenanceURL)
        )
        XCTAssertEqual(provenance.name, "VSP2 FASTQ Workflow")
        XCTAssertEqual(provenance.status.rawValue, RunStatus.completed.rawValue)
        XCTAssertEqual(provenance.parameters["workflowName"]?.stringValue, "VSP2 FASTQ Workflow")
        XCTAssertEqual(provenance.parameters["recipeRequiredInput"]?.stringValue, "paired")
        XCTAssertEqual(provenance.parameters["qualityBinning"]?.stringValue, "illumina4")
        XCTAssertTrue(provenance.steps.contains { $0.toolName == "lungfish-cli workflow builder-run" })
        XCTAssertTrue(
            provenance.primaryInputFiles.contains {
                sameFilePath($0.path, fixture.r1URL) && $0.sha256 != nil && $0.sizeBytes != nil
            },
            "\(provenance.primaryInputFiles)"
        )
        let r2URL = try XCTUnwrap(fixture.r2URL)
        XCTAssertTrue(
            provenance.primaryInputFiles.contains {
                sameFilePath($0.path, r2URL) && $0.sha256 != nil && $0.sizeBytes != nil
            },
            "\(provenance.primaryInputFiles)"
        )
        let outputFASTQPath = result.outputFASTQURL.path
        let outputBundlePath = result.outputBundleURL.path
        XCTAssertTrue(provenance.allOutputFiles.contains { record in
            record.path == outputFASTQPath && record.sha256 != nil && record.sizeBytes != nil
        })
        XCTAssertTrue(provenance.allOutputFiles.contains { $0.path == outputBundlePath })
    }

    func testRunnerRejectsSingleEndBundleForVSP2BeforeExecutingRecipe() async throws {
        let fixture = try makeSingleEndProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Single.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000602", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor()
        let runner = WorkflowBuilderNativeRunner(recipeExecutor: executor)

        do {
            _ = try await runner.run(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: runDirectory,
                workflowBundleURL: fixture.workflowBundleURL,
                argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
                threads: 2
            )
            XCTFail("Expected VSP2 input validation failure")
        } catch RecipeEngineError.inputRequirementNotMet(let required, let actual) {
            XCTAssertEqual(required, .paired)
            XCTAssertEqual(actual, .single)
        }

        XCTAssertTrue(executor.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent("outputs").path))
    }

    func testRunnerPreservesGzippedFASTQExtensionWhenBundlingRecipeOutput() async throws {
        let fixture = try makePairedProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000603", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor(outputFilename: "processed.fq.gz")
        let runner = WorkflowBuilderNativeRunner(recipeExecutor: executor)

        let result = try await runner.run(
            graph: graph,
            projectURL: fixture.projectURL,
            runDirectoryURL: runDirectory,
            workflowBundleURL: fixture.workflowBundleURL,
            argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
            threads: 2
        )

        XCTAssertTrue(result.outputFASTQURL.lastPathComponent.hasSuffix(".fastq.gz"))
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: result.outputBundleURL))
        if case .full(let fastqFilename) = manifest.payload {
            XCTAssertTrue(fastqFilename.hasSuffix(".fastq.gz"))
        } else {
            XCTFail("Expected single FASTQ derivative payload")
        }
    }

    func testRunnerMapsFusedFastpExecutionRecordAcrossSourceBuilderSteps() async throws {
        let fixture = try makePairedProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000604", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor(stepRecordMode: .fusedFastpPrefix)
        let runner = WorkflowBuilderNativeRunner(recipeExecutor: executor)

        let result = try await runner.run(
            graph: graph,
            projectURL: fixture.projectURL,
            runDirectoryURL: runDirectory,
            workflowBundleURL: fixture.workflowBundleURL,
            argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
            threads: 2
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: result.outputBundleURL))
        XCTAssertEqual(manifest.lineage.map(\.toolCommand), [
            "/tools/fastp --fused '/tmp/input with spaces/Sample_R1.fastq'",
            "/tools/fastp --fused '/tmp/input with spaces/Sample_R1.fastq'",
            "fake-tool deacon-scrub",
            "fake-tool fastp-merge",
            "fake-tool seqkit-length-filter",
        ])
    }

    func testRunnerStoresRecipeStepCommandAsExactArgv() async throws {
        let fixture = try makePairedProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000605", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor(stepRecordMode: .argvWithSpaces)
        let runner = WorkflowBuilderNativeRunner(recipeExecutor: executor)

        let result = try await runner.run(
            graph: graph,
            projectURL: fixture.projectURL,
            runDirectoryURL: runDirectory,
            workflowBundleURL: fixture.workflowBundleURL,
            argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
            threads: 2
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: result.provenanceURL))
        let step = try XCTUnwrap(provenance.steps.first { $0.toolName == "fastp-dedup" })
        XCTAssertEqual(step.command, [
            "/tools/fake tool",
            "--step",
            "fastp-dedup",
            "--input",
            "/tmp/input with spaces/Sample_R1.fastq",
        ])
    }

    func testRunnerRemovesOutputBundleWhenProvenanceWriteFails() async throws {
        enum InjectedFailure: Error {
            case provenance
        }

        let fixture = try makePairedProjectFixture()
        let graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/Sample.lungfishfastq")
        let runDirectory = fixture.workflowBundleURL
            .appendingPathComponent("runs/00000000-0000-4000-8000-000000000606", isDirectory: true)
        let executor = FakeWorkflowBuilderRecipeExecutor()
        let runner = WorkflowBuilderNativeRunner(
            recipeExecutor: executor,
            provenanceWriteInterceptor: { throw InjectedFailure.provenance }
        )

        do {
            _ = try await runner.run(
                graph: graph,
                projectURL: fixture.projectURL,
                runDirectoryURL: runDirectory,
                workflowBundleURL: fixture.workflowBundleURL,
                argv: ["lungfish-cli", "workflow", "builder-run", "--workflow", fixture.workflowBundleURL.path],
                threads: 2
            )
            XCTFail("Expected provenance write failure")
        } catch InjectedFailure.provenance {
        }

        let outputDirectory = runDirectory.appendingPathComponent("outputs", isDirectory: true)
        let outputContents = (try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(outputContents.contains { $0.pathExtension.lowercased() == "lungfishfastq" })
        XCTAssertFalse(outputContents.contains { $0.lastPathComponent.contains(".staging-") })
    }

    private struct ProjectFixture {
        let rootURL: URL
        let projectURL: URL
        let workflowBundleURL: URL
        let inputBundleURL: URL
        let r1URL: URL
        let r2URL: URL?
    }

    private func makePairedProjectFixture() throws -> ProjectFixture {
        let fixture = try makeProjectFixture(bundleName: "Sample")
        let r1 = fixture.inputBundleURL.appendingPathComponent("Sample_R1.fastq")
        let r2 = fixture.inputBundleURL.appendingPathComponent("Sample_R2.fastq")
        try "@r1\nACGTACGT\n+\n!!!!!!!!\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@r2\nTGCATGCA\n+\n!!!!!!!!\n".write(to: r2, atomically: true, encoding: .utf8)
        return ProjectFixture(
            rootURL: fixture.rootURL,
            projectURL: fixture.projectURL,
            workflowBundleURL: fixture.workflowBundleURL,
            inputBundleURL: fixture.inputBundleURL,
            r1URL: r1,
            r2URL: r2
        )
    }

    private func makeSingleEndProjectFixture() throws -> ProjectFixture {
        let fixture = try makeProjectFixture(bundleName: "Single")
        let r1 = fixture.inputBundleURL.appendingPathComponent("Single.fastq")
        try "@single\nACGTACGT\n+\n!!!!!!!!\n".write(to: r1, atomically: true, encoding: .utf8)
        return ProjectFixture(
            rootURL: fixture.rootURL,
            projectURL: fixture.projectURL,
            workflowBundleURL: fixture.workflowBundleURL,
            inputBundleURL: fixture.inputBundleURL,
            r1URL: r1,
            r2URL: nil
        )
    }

    private func makeProjectFixture(bundleName: String) throws -> ProjectFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-builder-native-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputBundleURL = projectURL.appendingPathComponent("Imports/\(bundleName).lungfishfastq", isDirectory: true)
        let workflowBundleURL = projectURL.appendingPathComponent("Workflows/VSP2.lungfishflow", isDirectory: true)
        try FileManager.default.createDirectory(at: inputBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workflowBundleURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ProjectFixture(
            rootURL: root,
            projectURL: projectURL,
            workflowBundleURL: workflowBundleURL,
            inputBundleURL: inputBundleURL,
            r1URL: inputBundleURL.appendingPathComponent("\(bundleName).fastq"),
            r2URL: nil
        )
    }

    private func sameFilePath(_ recordedPath: String, _ expectedURL: URL) -> Bool {
        URL(fileURLWithPath: recordedPath).resolvingSymlinksInPath().standardizedFileURL.path ==
            expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class FakeWorkflowBuilderRecipeExecutor: WorkflowBuilderRecipeExecuting, @unchecked Sendable {
    static let outputFASTQ = "@processed\nAACCGGTT\n+\n!!!!!!!!\n"

    enum StepRecordMode {
        case onePerRecipeStep
        case fusedFastpPrefix
        case argvWithSpaces
    }

    private let outputFilename: String
    private let stepRecordMode: StepRecordMode
    struct Invocation {
        let recipe: Recipe
        let input: StepInput
        let context: StepContext
    }

    private(set) var invocations: [Invocation] = []

    init(outputFilename: String = "processed.fastq", stepRecordMode: StepRecordMode = .onePerRecipeStep) {
        self.outputFilename = outputFilename
        self.stepRecordMode = stepRecordMode
    }

    func execute(recipe: Recipe, input: StepInput, context: StepContext) async throws -> RecipeExecutionResult {
        invocations.append(Invocation(recipe: recipe, input: input, context: context))
        try FileManager.default.createDirectory(at: context.workspace, withIntermediateDirectories: true)
        let outputURL = context.workspace.appendingPathComponent(outputFilename)
        try Self.outputFASTQ.write(to: outputURL, atomically: true, encoding: .utf8)
        return RecipeExecutionResult(
            output: StepOutput(r1: outputURL, format: .single, readCount: 1),
            stepRecords: stepRecords(for: recipe)
        )
    }

    private func stepRecords(for recipe: Recipe) -> [RecipeStepResult] {
        switch stepRecordMode {
        case .onePerRecipeStep:
            return recipe.steps.map { singleRecord(for: $0) }
        case .fusedFastpPrefix:
            guard recipe.steps.count >= 2 else { return recipe.steps.map { singleRecord(for: $0) } }
            return [
                RecipeStepResult(
                    stepName: "\(recipe.steps[0].label ?? recipe.steps[0].type) + \(recipe.steps[1].label ?? recipe.steps[1].type)",
                    tool: "fastp",
                    toolVersion: "fake-1.0",
                    commandLine: "/tools/fastp --fused '/tmp/input with spaces/Sample_R1.fastq'",
                    commandArguments: ["/tools/fastp", "--fused", "/tmp/input with spaces/Sample_R1.fastq"],
                    outputReadCount: 1,
                    durationSeconds: 0.01
                ),
            ] + recipe.steps.dropFirst(2).map { singleRecord(for: $0) }
        case .argvWithSpaces:
            return recipe.steps.map { step in
                RecipeStepResult(
                    stepName: step.label ?? step.type,
                    tool: step.type,
                    toolVersion: "fake-1.0",
                    commandLine: "'/tools/fake tool' --step \(step.type) --input '/tmp/input with spaces/Sample_R1.fastq'",
                    commandArguments: [
                        "/tools/fake tool",
                        "--step",
                        step.type,
                        "--input",
                        "/tmp/input with spaces/Sample_R1.fastq",
                    ],
                    outputReadCount: 1,
                    durationSeconds: 0.01
                )
            }
        }
    }

    private func singleRecord(for step: RecipeStep) -> RecipeStepResult {
        RecipeStepResult(
            stepName: step.label ?? step.type,
            tool: step.type,
            toolVersion: "fake-1.0",
            commandLine: "fake-tool \(step.type)",
            outputReadCount: 1,
            durationSeconds: 0.01
        )
    }
}
