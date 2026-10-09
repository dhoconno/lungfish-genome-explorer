// GenotypeUISourceTestSupport.swift - shared source-introspection helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The genotype UI code is spread over many files and keeps moving into new
// ones. An absence guard that reads one file passes trivially once the code it
// polices has moved out, so it stops guarding anything. This helper returns
// every Swift file of the LungfishGenotypeUI module as one string, so an
// absence guard covers the code wherever it lands. Use it for absence checks
// across the module. A check that something is present, or one tied to a
// single file, keeps reading that file.

import Foundation

/// Directory holding the Swift sources of the LungfishGenotypeUI module.
private func genotypeUISourceDirectory() -> URL {
    // #filePath = .../Tests/Support/LungfishTestSupport/GenotypeUISourceTestSupport.swift
    // repo root = four levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishTestSupport
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent("Sources/LungfishGenotypeUI", isDirectory: true)
}

/// Returns the source of every Swift file under Sources/LungfishGenotypeUI,
/// sorted by path and joined with newlines.
///
/// It throws when the module holds no Swift file, so an absence assertion can
/// never pass on an empty string. A file that cannot be read also throws and is
/// never skipped. Never slice the result between two anchors, because the
/// order follows file paths and not the order of the code.
public func combinedGenotypeUISource() throws -> String {
    let directory = genotypeUISourceDirectory()
    let files = try repositoryFiles(under: directory)
    guard !files.isEmpty else {
        throw CocoaError(
            .fileReadNoSuchFile,
            userInfo: [
                NSFilePathErrorKey: directory.path,
                NSLocalizedDescriptionKey: "No Swift source files found under \(directory.path)",
            ]
        )
    }
    return try files.map { try readRepositorySource($0) }.joined(separator: "\n")
}
