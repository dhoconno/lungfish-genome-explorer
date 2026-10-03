// InspectorVariantWorkflowOperationTests.swift - begin() sites in InspectorViewController+VariantWorkflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both variant-calling launches lock the bundle (R4). A held lock must refuse
// the row and launch nothing, and the recorded row must carry its type, its
// lock and its command. The GATK run has no lungfish-cli equivalent yet, so
// its test pins today's command and fails when one is added.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class InspectorVariantWorkflowOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a1/Sample.lungfishref", isDirectory: true)

    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Primer-trimming with QIAseq Direct",
            detail: "Running",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam primer-trim"
        ).startedID)
        return center
    }

    // MARK: - Variant calling through lungfish-cli

    private func variantCallingArguments() -> [String] {
        CLIVariantCallingRunner.buildCLIArguments(request: BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 \u{2022} LoFreq",
            threads: 4,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10
        ))
    }

    func testVariantCallingRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginVariantCallingOperation(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            bundleURL: bundleURL,
            cliArguments: variantCallingArguments(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the variant-calling row")
        }
        XCTAssertFalse(launched, "a refused row must launch no runner")
        XCTAssertEqual(refusal.blockingOperationTitle, "Primer-trimming with QIAseq Direct")
    }

    func testVariantCallingRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        var launchedID: UUID?

        InspectorViewController.beginVariantCallingOperation(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            bundleURL: bundleURL,
            cliArguments: variantCallingArguments(),
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.operationType, .variantCalling)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: VariantsCommand.CallSubcommand.self)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.caller, "lofreq")
        XCTAssertEqual(command.outputTrackName, "Sample 1 \u{2022} LoFreq")
        XCTAssertEqual(command.minimumAlleleFrequency, 0.05)
        XCTAssertEqual(command.minimumDepth, 10)
    }

    // MARK: - GATK, a CLI parity gap

    private func gatkRequest() -> GATKPipelineExecutionRequest {
        let directory = URL(fileURLWithPath: "/tmp/lane 1a1/gatk", isDirectory: true)
        let reference = directory.appendingPathComponent("reference.fa")
        let bam = directory.appendingPathComponent("sample.bam")
        let output = directory.appendingPathComponent("sample.vcf.gz")
        return GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: "4.6.2.0",
            command: GATKCommand(arguments: [
                "HaplotypeCaller", "-R", reference.path, "-I", bam.path, "-O", output.path,
            ]),
            outputDirectory: directory,
            inputs: [
                GATKFileArtifact(url: reference, format: .fasta, role: .reference),
                GATKFileArtifact(url: bam, format: .bam, role: .input),
            ],
            outputs: [GATKFileArtifact(url: output, format: .vcf, role: .output)],
            options: [:],
            resolvedDefaults: [:]
        )
    }

    func testGATKVariantCallingRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginGATKVariantCallingOperation(
            title: "Calling variants with GATK HaplotypeCaller",
            detail: "Running GATK HaplotypeCaller...",
            bundleURL: bundleURL,
            request: gatkRequest(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused = result else {
            return XCTFail("a held bundle lock must refuse the GATK row")
        }
        XCTAssertFalse(launched, "a refused row must start no GATK pipeline and attach nothing")
    }

    func testGATKVariantCallingRecordsNoCommandAsAParityGapAndLogsTheGATKCommands() throws {
        let reporter = RecordingOperationReporter()
        let request = gatkRequest()

        InspectorViewController.beginGATKVariantCallingOperation(
            title: "Calling variants with GATK HaplotypeCaller",
            detail: "Running GATK HaplotypeCaller...",
            bundleURL: bundleURL,
            request: request,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.operationType, .variantCalling)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        // No lungfish-cli command runs GATK and attaches the VCF to the
        // bundle. The closest is `gatk haplotype-caller --execute`. The row
        // records no command and logs the GATK commands instead.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "gatk-variant-calling")
        XCTAssertEqual(
            item.logs.map(\.message),
            request.commands.map { "GATK command: \($0.shellCommand)" }
        )
    }
}
