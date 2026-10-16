// CLIReferenceBundleWrapper.swift - Wraps a FASTA a FASTQ operation wrote as a reference bundle with lungfish-cli import fasta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Wraps a FASTA that a FASTQ operation wrote as a `.lungfishref` bundle by running
/// `lungfish-cli import fasta` on ``CLIBundleBuildRunner`` (2.11 lane A48 M4, plan decision C3).
///
/// The command builds the bundle in the operation's destination folder as given (`--bundle-dir`),
/// merges the FASTA's own record into the bundle's (`--rehydrate-source-provenance`) and publishes,
/// so the app writes nothing after it exits (plan decision C5). The operation's row is the FASTQ
/// operation's, so the command's events reach no row, and a cancel of the operation's task stops it.
struct CLIReferenceBundleWrapper: ReferenceBundleWrapping {
    /// The `lungfish-cli` to run, for a test. Nil finds the bundled one.
    var cliURLOverride: URL?

    init(cliURLOverride: URL? = nil) {
        self.cliURLOverride = cliURLOverride
    }

    func importReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?
    ) async throws -> URL {
        let result = try await CLIBundleBuildRunner(cliURLOverride: cliURLOverride).run(
            arguments: Self.arguments(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredBundleName
            )
        )
        guard let path = result.outputs.first else { throw ReferenceImportRunError.noBundle }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The argv after `lungfish-cli` that wraps `sourceURL` in `outputDirectory` and prints its
    /// events. A blank name is no name, as the service treats it.
    static func arguments(sourceURL: URL, outputDirectory: URL, preferredBundleName: String?) -> [String] {
        let name = preferredBundleName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ReferenceBundleImportService.importFASTAArguments(
            sourceURL: sourceURL,
            projectURL: nil,
            bundleFolderURL: outputDirectory,
            preferredBundleName: name,
            rehydrateSourceProvenance: true
        ) + ["--format", "json"]
    }
}
