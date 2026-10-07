// PortableRename+Simulation.swift - Run renames as if the volume were ExFAT
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

extension PortableRename.Operations {
    /// The environment variable that makes every flagged rename behave as on
    /// ExFAT. Honoured only in Debug builds.
    package static let simulateUnsupportedFlagsVariable = "LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS"

    /// The operations every rename uses: ``darwin`` unless a test has
    /// overridden them for the current task.
    package static var current: PortableRename.Operations {
        PortableRename.overrideOperations ?? .darwin
    }

    package static func forEnvironment(_ environment: [String: String]) -> PortableRename.Operations {
        simulatesUnsupportedFlags(environment) ? unsupportedFlags : PortableRename.Operations()
    }

    /// Whether this process runs every flagged rename down its fallback.
    /// A test that asserts the APFS kernel path skips when it is `true`.
    package static let processSimulatesUnsupportedFlags = simulatesUnsupportedFlags(ProcessInfo.processInfo.environment)

    /// The system calls of a volume without `RENAME_EXCL` or `RENAME_SWAP`.
    package static let unsupportedFlags = PortableRename.Operations(
        nativeRename: { sourceParent, sourceName, destinationParent, destinationName, flags in
            guard flags == 0 else {
                errno = ENOTSUP
                return -1
            }
            return Darwin.renameatx_np(sourceParent, sourceName, destinationParent, destinationName, 0)
        }
    )

    private static func simulatesUnsupportedFlags(_ environment: [String: String]) -> Bool {
        #if DEBUG
        return environment[simulateUnsupportedFlagsVariable] == "1"
        #else
        return false
        #endif
    }
}

extension PortableRename {
    /// Replaces the system calls for the current task and the synchronous
    /// calls it makes. Tests use ``simulatingUnsupportedFlags(_:)``.
    @TaskLocal package static var overrideOperations: Operations?

    /// Runs `body` as if the volume were ExFAT: every rename with
    /// `RENAME_EXCL` or `RENAME_SWAP` takes its fallback.
    package static func simulatingUnsupportedFlags<Result>(_ body: () throws -> Result) rethrows -> Result {
        try $overrideOperations.withValue(Operations.unsupportedFlags, operation: body)
    }

    package static func simulatingUnsupportedFlags<Result>(
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        try await $overrideOperations.withValue(Operations.unsupportedFlags, operation: body)
    }
}
