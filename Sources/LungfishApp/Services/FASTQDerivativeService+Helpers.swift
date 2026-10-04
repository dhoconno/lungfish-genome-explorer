// FASTQDerivativeService+Helpers.swift - Helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    // MARK: - Helpers

    func makeTemporaryDirectory(prefix: String, contextURL: URL? = nil) throws -> URL {
        if let contextURL {
            return try ProjectTempDirectory.createFromContext(prefix: prefix, contextURL: contextURL)
        }
        return try ProjectTempDirectory.create(prefix: prefix, in: nil)
    }

    /// Whether the bundle's reads are strictly interleaved pairs, by the same
    /// resolver every FASTQ consumer uses (metadata, then a record scan).
    nonisolated func isInterleavedBundle(_ bundleURL: URL) -> Bool {
        FASTQInputLayoutResolver.resolve(inputURLs: [bundleURL]).layout == .strictlyInterleaved
    }

    func normalizedIdentifier(_ identifier: String) -> String {
        var value = identifier
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value
    }
}
