// NCBITaxonomyFixture.swift - Local stand-in for the NCBI taxdump download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Installs a small NCBI Taxonomy in place of the 80 MB taxdump download.
///
/// A NAO-MGS import installs the taxonomy into its registry when names are
/// missing. Give the import a registry under a temporary root built with
/// ``installer(archive:scientificNames:)`` so the install stays off the network
/// and out of the user's managed storage.
public enum NCBITaxonomyFixture {
    /// An installer whose download writes `archive` and whose extraction writes
    /// `names.dmp` and `nodes.dmp` holding `scientificNames`.
    public static func installer(archive: URL, scientificNames: [Int: String]) -> MetagenomicsDatabaseInstaller {
        MetagenomicsDatabaseInstaller(
            toolRunner: UnusedToolRunner(),
            archiveTransfer: TaxdumpTransfer(archive: archive, scientificNames: scientificNames),
            provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
        )
    }

    private struct TaxdumpTransfer: MetagenomicsDatabaseArchiveTransferring {
        let archive: URL
        let scientificNames: [Int: String]

        func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture taxdump".utf8).write(to: archive)
            progress(1)
            return archive
        }

        func extractionToolVersion() async throws -> String { "bsdtar fixture" }

        func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let taxIDs = scientificNames.keys.sorted()
            let names = taxIDs.map { "\($0)\t|\t\(scientificNames[$0]!)\t|\t\t|\tscientific name\t|\n" }.joined()
            let nodes = "1\t|\t1\t|\tno rank\t|\n" + taxIDs.map { "\($0)\t|\t1\t|\tspecies\t|\n" }.joined()
            try names.write(to: destination.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
            try nodes.write(to: destination.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
            return MetagenomicsDatabaseToolResult(
                stdout: "", stderr: "", exitStatus: 0,
                argv: ["/usr/bin/tar", "xzf", archive.path, "-C", destination.path],
                runtimeIdentity: .fixture(executablePath: "/usr/bin/tar", condaEnvironment: nil),
                toolVersion: "bsdtar fixture", startedAt: Date(), completedAt: Date()
            )
        }
    }

    /// The taxdump recipe is an archive, so the installer never runs a managed tool.
    private struct UnusedToolRunner: MetagenomicsDatabaseToolRunning {
        struct UnexpectedRun: Error {}

        func run(name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval) async throws -> MetagenomicsDatabaseToolResult {
            throw UnexpectedRun()
        }

        func executableDirectory(environment: String) async throws -> URL { throw UnexpectedRun() }

        func toolVersion(name: String, environment: String, workingDirectory: URL) async throws -> String { throw UnexpectedRun() }
    }
}
