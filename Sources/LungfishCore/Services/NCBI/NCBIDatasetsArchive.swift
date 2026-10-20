// NCBIDatasetsArchive.swift - Unpacks the ZIP the NCBI Datasets API returns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Unpacks a Datasets download with `/usr/bin/unzip` on ``ToolProcess``, so
/// one primitive drains, bounds and cancels the tool.
enum NCBIDatasetsArchive {
    static func extract(
        _ zipURL: URL,
        to directory: URL,
        unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip")
    ) async throws {
        let spec = ToolProcessSpec(
            executableURL: unzipURL,
            arguments: ["-q", "-o", zipURL.path, "-d", directory.path],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: .discard,
            stderr: .discard,
            label: "unzip"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.cancelled {
            throw DatabaseServiceError.cancelled
        }
        guard result.isSuccess else {
            throw DatabaseServiceError.parseError(message: "Failed to extract Datasets ZIP (exit \(result.status))")
        }
    }
}
