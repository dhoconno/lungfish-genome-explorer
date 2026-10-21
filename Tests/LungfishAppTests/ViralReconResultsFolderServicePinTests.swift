// ViralReconResultsFolderServicePinTests.swift - The service's rebuilt requests meet a results folder nothing has staged into
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.21 STALE-OUT, M1. The service builds its request twice more after the wizard built the first,
// once after it acquires the reference (the primer completes beside the staged inputs) and once after it copies the
// samplesheet, the primers and the Nanopore files into the run bundle. A check on the results folder inside the
// request's `init` is only safe while neither step stages a file into that folder, so this pin runs the whole
// preparation and lists the folder at the moment the CLI would launch. It passes at the base and must keep passing.

import LungfishKit
import LungfishKitTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ViralReconResultsFolderServicePinTests: XCTestCase {
    func testBothRebuiltRequestsMeetAnEmptyResultsFolderAndStageNothingInIt() async throws {
        try await assertPreparationLeavesTheResultsFolderAlone(removeFolderFirst: false)
    }

    func testBothRebuiltRequestsMeetAMissingResultsFolderAndStageNothingInIt() async throws {
        try await assertPreparationLeavesTheResultsFolderAlone(removeFolderFirst: true)
    }

    private func assertPreparationLeavesTheResultsFolderAlone(
        removeFolderFirst: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-results-service-pin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
        let outputs = request.outputDirectory
        if removeFolderFirst {
            try FileManager.default.removeItem(at: outputs)
        }
        let project = temp.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let runner = ResultsFolderProbeRunner(watching: outputs)
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            referenceDownloader: { _, destination in
                let bundle = destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try ">\(ViralReconReferenceCatalog.canonicalAccession) SARS-CoV-2\nACGTACGTACGTACGTACGTACGTACGTACGT\n"
                    .write(
                        to: bundle.appendingPathComponent("sequence.fasta"),
                        atomically: true,
                        encoding: .utf8
                    )
            }
        )

        _ = try await service.run(
            request,
            bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: project
        )

        XCTAssertEqual(runner.launchCount, 1, "both rebuilt requests were accepted, so the run reached the launch", file: file, line: line)
        XCTAssertEqual(runner.folderExistedAtLaunch, !removeFolderFirst, file: file, line: line)
        XCTAssertEqual(runner.entriesAtLaunch, [], "no staged file sits in the results folder before the launch", file: file, line: line)
    }
}

/// Stands in for the CLI. At the launch, which comes after both rebuilt requests, it records what the results folder
/// holds.
private final class ResultsFolderProbeRunner: ViralReconWorkflowProcessRunning {
    private(set) var launchCount = 0
    private(set) var folderExistedAtLaunch: Bool?
    private(set) var entriesAtLaunch: [String]?
    private let watchedFolder: URL

    init(watching folder: URL) {
        watchedFolder = folder
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        launchCount += 1
        folderExistedAtLaunch = FileManager.default.fileExists(atPath: watchedFolder.path)
        entriesAtLaunch = (try? FileManager.default.contentsOfDirectory(atPath: watchedFolder.path)) ?? []
        return ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    func cancel() {}
}
