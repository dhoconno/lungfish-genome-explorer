// FASTQDerivativeService+MixedOutput.swift - Mixed output derivatives
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    // MARK: - Mixed Output Derivatives

    func runNativeTool(
        _ tool: NativeTool,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?
    ) async throws -> NativeToolResult {
        let toolClock = ProvenanceRunClock()
        let result = try await runner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        let completedAt = toolClock.now
        if let provenanceCollector {
            let toolVersion = await runner.getToolVersion(tool)
            provenanceCollector.append(
                FASTQDerivativeNativeToolExecution(
                    tool: tool,
                    toolVersion: toolVersion,
                    result: result,
                    startedAt: toolClock.startedAt,
                    completedAt: completedAt
                )
            )
        }
        return result
    }
}
