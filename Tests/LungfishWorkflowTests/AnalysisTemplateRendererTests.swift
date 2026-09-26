// AnalysisTemplateRendererTests.swift - Golden argv for rendered template steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

final class AnalysisTemplateRendererTests: XCTestCase {

    private func makeTemplate(
        pairing: AnalysisTemplatePairing,
        readFormat: ClassificationConfig.ReadFormat,
        goal: Kraken2StepSpec.Goal = .classify,
        recipe: RecipeSnapshot? = nil,
        optimizeStorage: Bool = true,
        clumpingTool: ClumpingTool = .auto,
        extraArguments: [String] = [],
        bracken: BrackenProfileRequest? = nil,
        memoryMapping: Bool = false,
        quickMode: Bool = false
    ) -> AnalysisTemplate {
        AnalysisTemplate(
            name: "Test",
            origin: AnalysisTemplate.Origin(appVersion: "test", sourceAnalysisRelativePath: "Analyses/kraken2-x"),
            input: AnalysisTemplate.InputSpec(platform: .illumina, pairing: pairing),
            steps: [
                .importFASTQ(ImportFASTQStepSpec(
                    platform: .illumina,
                    pairing: pairing,
                    qualityBinning: .none,
                    optimizeStorage: optimizeStorage,
                    clumpingTool: clumpingTool,
                    compressionLevel: .fast,
                    recipe: recipe
                )),
                .kraken2(Kraken2StepSpec(
                    goal: goal,
                    database: Kraken2StepSpec.DatabaseIdentity(name: "Viral", version: "20260626"),
                    readFormat: readFormat,
                    confidence: 0.5,
                    minimumHitGroups: 3,
                    memoryMapping: memoryMapping,
                    quickMode: quickMode,
                    extraArguments: extraArguments,
                    bracken: bracken
                )),
            ]
        )
    }

    private let project = URL(fileURLWithPath: "/tmp/P.lungfish")

    func testPairedImportWithRecipeAndThreads() throws {
        let template = makeTemplate(
            pairing: .paired,
            readFormat: .interleaved,
            recipe: RecipeSnapshot(id: "vsp2-target-enrichment", name: "VSP2")
        )
        let steps = try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/data/S1_R1.fastq.gz"), URL(fileURLWithPath: "/data/S1_R2.fastq.gz")],
            projectURL: project,
            threads: 6,
            analysisDirectoryURL: project.appendingPathComponent("Analyses/kraken2-now")
        ))

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .importFASTQ)
        XCTAssertEqual(steps[0].arguments, [
            "import", "fastq", "/data/S1_R1.fastq.gz", "/data/S1_R2.fastq.gz",
            "--project", "/tmp/P.lungfish",
            "--platform", "illumina",
            "--pairing", "paired",
            "--format", "json",
            "--quality-binning", "none",
            "--compression", "fast",
            "--name", "S1",
            "--recipe", "vsp2-target-enrichment",
            "--threads", "6",
        ])
        XCTAssertEqual(steps[0].expectedOutputURL.path, "/tmp/P.lungfish/Imports/S1.lungfishfastq")

        XCTAssertEqual(steps[1].kind, .kraken2)
        XCTAssertEqual(steps[1].arguments, [
            "conda", "classify",
            "--db", "Viral",
            "--output-dir", "/tmp/P.lungfish/Analyses/kraken2-now",
            "--confidence", "0.5",
            "--min-hit-groups", "3",
            "--threads", "6",
            "--read-format", "interleaved",
            "/tmp/P.lungfish/Imports/S1.lungfishfastq",
        ])
        XCTAssertEqual(steps[1].expectedOutputURL.path, "/tmp/P.lungfish/Analyses/kraken2-now")
        XCTAssertTrue(steps[1].commandLine.hasPrefix("lungfish-cli conda classify --db Viral"))
    }

    func testSingleEndWithoutThreadsLeavesCLIDefaults() throws {
        let template = makeTemplate(pairing: .single, readFormat: .unpaired, optimizeStorage: false)
        let steps = try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/data/ont.fastq.gz")],
            projectURL: project,
            sampleName: "Sample A"
        ))

        XCTAssertEqual(steps[0].arguments, [
            "import", "fastq", "/data/ont.fastq.gz",
            "--project", "/tmp/P.lungfish",
            "--platform", "illumina",
            "--pairing", "single",
            "--format", "json",
            "--quality-binning", "none",
            "--compression", "fast",
            "--name", "Sample A",
            "--no-optimize-storage",
        ])
        XCTAssertFalse(steps[1].arguments.contains("--threads"))
        XCTAssertEqual(steps[1].arguments.suffix(3), ["--read-format", "unpaired", "/tmp/P.lungfish/Imports/Sample A.lungfishfastq"])
        XCTAssertEqual(steps[1].expectedOutputURL.path, "/tmp/P.lungfish/Analyses/kraken2-<timestamp>")
    }

    func testInterleavedImportWithExplicitClumpingTool() throws {
        let template = makeTemplate(pairing: .interleaved, readFormat: .interleaved, clumpingTool: .bbtools)
        let steps = try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/data/il.fastq")],
            projectURL: project
        ))
        XCTAssertTrue(steps[0].arguments.contains("--pairing"))
        XCTAssertEqual(steps[0].arguments[steps[0].arguments.firstIndex(of: "--pairing")! + 1], "interleaved")
        XCTAssertEqual(steps[0].arguments.suffix(2), ["--clumping-tool", "bbtools"])
        XCTAssertEqual(steps[0].arguments[steps[0].arguments.firstIndex(of: "--name")! + 1], "il")
    }

    func testProfileWithBrackenExtraArgsAndFlags() throws {
        let template = makeTemplate(
            pairing: .paired,
            readFormat: .interleaved,
            goal: .profile,
            extraArguments: ["--use-names", "--minimum-base-quality", "20"],
            bracken: BrackenProfileRequest(rank: .explicit(.genus), readLength: 100, threshold: 5),
            memoryMapping: true,
            quickMode: true
        )
        let steps = try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/d/x_1.fq.gz"), URL(fileURLWithPath: "/d/x_2.fq.gz")],
            projectURL: project,
            threads: 2,
            analysisDirectoryURL: project.appendingPathComponent("Analyses/k")
        ))
        XCTAssertEqual(steps[1].arguments, [
            "conda", "classify",
            "--db", "Viral",
            "--output-dir", "/tmp/P.lungfish/Analyses/k",
            "--confidence", "0.5",
            "--min-hit-groups", "3",
            "--threads", "2",
            "--read-format", "interleaved",
            "--memory-mapping",
            "--quick",
            "--extra-args", "--use-names --minimum-base-quality 20",
            "--profile",
            "--bracken-read-length", "100",
            "--bracken-threshold", "5",
            "--bracken-level", "G",
            "/tmp/P.lungfish/Imports/x.lungfishfastq",
        ])
    }

    func testClassificationInputOverrideIsUsedForKraken2() throws {
        let template = makeTemplate(pairing: .single, readFormat: .unpaired)
        let steps = try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/data/a.fastq")],
            projectURL: project,
            classificationInputs: [URL(fileURLWithPath: "/tmp/P.lungfish/Imports/a.lungfishfastq/a.fastq.gz")]
        ))
        XCTAssertEqual(steps[1].arguments.last, "/tmp/P.lungfish/Imports/a.lungfishfastq/a.fastq.gz")
    }

    func testInputCountMismatchIsRefused() {
        let template = makeTemplate(pairing: .paired, readFormat: .interleaved)
        XCTAssertThrowsError(try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/data/only_one.fastq")],
            projectURL: project
        ))) { error in
            XCTAssertEqual(error as? AnalysisTemplateRenderError, .inputCountMismatch(expected: 2, found: 1))
        }
    }

    func testPairedKraken2FromOneBundleIsRefusedWithoutTwoFiles() {
        let template = makeTemplate(pairing: .paired, readFormat: .paired)
        XCTAssertThrowsError(try AnalysisTemplateRenderer.render(template, request: AnalysisTemplateRenderRequest(
            inputs: [URL(fileURLWithPath: "/d/x_1.fq.gz"), URL(fileURLWithPath: "/d/x_2.fq.gz")],
            projectURL: project
        ))) { error in
            XCTAssertEqual(error as? AnalysisTemplateRenderError, .pairedInputsUnavailable)
        }
    }

    func testPlaceholderStepsAndShellScript() {
        let template = makeTemplate(pairing: .paired, readFormat: .interleaved, goal: .profile)
        let steps = AnalysisTemplateRenderer.placeholderSteps(for: template)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(Array(steps[0].arguments[2...3]), ["<reads_R1.fastq.gz>", "<reads_R2.fastq.gz>"])
        XCTAssertTrue(steps[0].arguments.contains("<project.lungfish>"))
        XCTAssertTrue(steps[0].arguments.contains("<sample>"))
        XCTAssertEqual(steps[1].arguments.last, "<project.lungfish>/Imports/<sample>.lungfishfastq")
        XCTAssertTrue(steps[1].arguments.contains("<project.lungfish>/Analyses/kraken2-<timestamp>"))

        let script = AnalysisTemplateRenderer.shellScript(for: template, steps: steps)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n# Workflow template: Test"))
        XCTAssertTrue(script.contains("lungfish-cli import fastq '<reads_R1.fastq.gz>' '<reads_R2.fastq.gz>'"))
        XCTAssertTrue(script.contains("lungfish-cli conda classify --db Viral"))
        XCTAssertTrue(script.contains("--profile"))
        XCTAssertTrue(script.contains("same steps with the same settings"))
        XCTAssertFalse(script.contains("same results"))
    }
}
