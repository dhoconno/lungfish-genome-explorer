// WorkflowRunExecutorValidationTests.swift - `workflow run --executor conda|local` is refused like the app refuses it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class WorkflowRunExecutorValidationTests: XCTestCase {
    private func request(executor: NFCoreExecutor) throws -> NFCoreRunRequest {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        return NFCoreRunRequest(
            workflow: workflow,
            version: "",
            executor: executor,
            inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results")
        )
    }

    func testDockerIsAccepted() throws {
        XCTAssertNoThrow(try RunSubcommand.requireSupportedExecutor(try request(executor: .docker)))
    }

    func testCondaAndLocalAreRefusedWithTheAppsMessage() throws {
        for executor in [NFCoreExecutor.conda, .local] {
            let appMessage = NFCoreRunRequest.UnsupportedExecutorError.unsupported(executor).localizedDescription
            XCTAssertThrowsError(try RunSubcommand.requireSupportedExecutor(try request(executor: executor))) { error in
                guard let validation = error as? ValidationError else {
                    return XCTFail("expected a ValidationError, got \(error)")
                }
                XCTAssertEqual(validation.message, appMessage)
            }
        }
    }

    func testTheOptionStillParsesEveryExecutorSoOldRunBundlesDecode() throws {
        for executor in [NFCoreExecutor.docker, .conda, .local] {
            let parsed = try RunSubcommand.parse(["nf-core/viralrecon", "--input", "/tmp/s.csv", "--executor", executor.rawValue])
            XCTAssertEqual(parsed.executor, executor)
        }
    }
}
