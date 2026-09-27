// CLIErrorMissingToolTests.swift - Missing tools exit with the documented status and a message
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishWorkflow

final class CLIErrorMissingToolTests: XCTestCase {
    /// `lungfish-cli map` without minimap2 used to exit 64 (generic workflow
    /// failure); the CLI reference documents 126 for a missing tool. The
    /// pipeline's own message is kept so it prints without `--debug`.
    func testMapperNotInstalledBecomesTheDocumentedMissingToolFailure() {
        let wrapped = CLIError.wrapping(ManagedMappingPipelineError.mapperNotInstalled("minimap2"))
        guard case .missingTool(let reason) = wrapped else {
            return XCTFail("expected missingTool, got \(wrapped)")
        }
        XCTAssertEqual(wrapped.exitCode, .dependency)
        XCTAssertEqual(wrapped.exitCode.rawValue, 126)
        XCTAssertTrue(reason.contains("minimap2 is not installed"), reason)
        let message = try! XCTUnwrap(wrapped.errorDescription)
        XCTAssertTrue(message.contains("minimap2 is not installed"), message)
        XCTAssertTrue(message.hasPrefix("Required tool is missing"), message)
        XCTAssertFalse(LungfishCLI.fullMessage(for: wrapped).isEmpty)
    }

    /// `ManagedMappingPipeline` (used by `map` and the genotyping pipelines)
    /// and `Minimap2Pipeline` (used by the Import Center) each had their own
    /// wording for a missing minimap2. They now share one message that names
    /// the Read Mapping plugin pack and the CLI install command, and both
    /// still take the exit-126 missing-tool path.
    func testMinimap2MissingMessageIsTheSameFromEveryPipeline() throws {
        let managed = ManagedMappingPipelineError.mapperNotInstalled("minimap2")
        let native = Minimap2PipelineError.minimap2NotInstalled
        let managedMessage = try XCTUnwrap(managed.errorDescription)
        let nativeMessage = try XCTUnwrap(native.errorDescription)
        XCTAssertEqual(managedMessage, nativeMessage)
        XCTAssertEqual(managedMessage, MissingToolMessage.readMappingTool("minimap2"))
        XCTAssertTrue(managedMessage.hasPrefix("minimap2 is not installed."), managedMessage)
        XCTAssertTrue(managedMessage.contains("Read Mapping plugin pack"), managedMessage)
        XCTAssertTrue(managedMessage.contains("lungfish-cli conda install --pack read-mapping"), managedMessage)
        XCTAssertFalse(managedMessage.contains("lungfish conda"), managedMessage)
        for error in [managed as any Error, native as any Error] {
            let wrapped = CLIError.wrapping(error)
            guard case .missingTool(let reason) = wrapped else {
                return XCTFail("\(error) must map to missingTool, got \(wrapped)")
            }
            XCTAssertEqual(wrapped.exitCode.rawValue, 126)
            XCTAssertEqual(reason, managedMessage)
        }
        // Other mappers keep the same shape with their own name.
        XCTAssertTrue(ManagedMappingPipelineError.mapperNotInstalled("bwa-mem2").errorDescription!
            .hasPrefix("bwa-mem2 is not installed. Install the Read Mapping plugin pack"))
    }

    func testEveryPipelineNotInstalledCaseIsRecognised() {
        let missing: [any Error] = [
            ManagedMappingPipelineError.mapperNotInstalled("bwa-mem2"),
            Minimap2PipelineError.minimap2NotInstalled,
            ClassificationPipelineError.kraken2NotInstalled,
            ClassificationPipelineError.brackenNotInstalled,
            EsVirituPipelineError.esVirituNotInstalled,
            TaxTriagePipelineError.nextflowNotInstalled,
            FASTQIngestionError.toolNotFound("seqkit"),
            NativeToolError.toolNotFound("samtools"),
            CondaError.toolNotFound(tool: "gatk", environment: "gatk-core"),
        ]
        for error in missing {
            let wrapped = CLIError.wrapping(error)
            guard case .missingTool = wrapped else {
                return XCTFail("\(error) must map to missingTool, got \(wrapped)")
            }
            XCTAssertEqual(wrapped.exitCode.rawValue, 126, "\(error)")
        }
    }

    func testOtherFailuresStayGenericWorkflowFailures() {
        let generic = CLIError.wrapping(ManagedMappingPipelineError.stagingFailed("disk full"))
        guard case .workflowFailed(let reason) = generic else {
            return XCTFail("expected workflowFailed, got \(generic)")
        }
        XCTAssertEqual(generic.exitCode.rawValue, 64)
        XCTAssertEqual(reason, "disk full")

        // An existing CLIError passes through untouched.
        let passthrough = CLIError.wrapping(CLIError.inputFileNotFound(path: "/x"))
        guard case .inputFileNotFound(let path) = passthrough else {
            return XCTFail("expected passthrough, got \(passthrough)")
        }
        XCTAssertEqual(path, "/x")
    }
}
