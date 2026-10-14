// BuildDbStreamCapture.swift - Runs the three build-db leaves in process on small fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI

/// Runs `build-db kraken2`, `build-db esviritu` and `build-db taxtriage` in process and keeps what they
/// print, so a test can compare a run with what the same run printed at an earlier commit.
///
/// The fixtures need no external tool. Kraken2 copies `Tests/Fixtures/kraken2-mini`. EsViritu and TaxTriage
/// copy `esviritu-mini` and `taxtriage-mini` without their BAMs, because both leaves run samtools on every BAM
/// that a row names, and no row names a BAM that is absent. Each run has a scratch folder of its own, which
/// `ImportStreamCapture.capture` rewrites to `/work` in every line.
enum BuildDbStreamCapture {
    static var fixturesFolder: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    /// `kraken2-mini`, three sample folders that each hold a kreport and the per-read output.
    static func kraken2Result(in scratch: ImportStreamCapture.Scratch) throws -> URL {
        try copyFixture("kraken2-mini", to: scratch.root.appendingPathComponent("kraken2", isDirectory: true))
    }

    /// `esviritu-mini`, three sample folders with their three tables and without the `<sample>_temp`
    /// folders that hold the BAMs.
    static func esVirituResultWithoutBAMs(in scratch: ImportStreamCapture.Scratch) throws -> URL {
        try copyFixture("esviritu-mini", to: scratch.root.appendingPathComponent("esviritu", isDirectory: true)) {
            $0.lastPathComponent.hasSuffix("_temp")
        }
    }

    /// `taxtriage-mini` without `minimap2`, the folder that holds its BAMs.
    static func taxTriageResultWithoutBAMs(in scratch: ImportStreamCapture.Scratch) throws -> URL {
        try copyFixture("taxtriage-mini", to: scratch.root.appendingPathComponent("taxtriage", isDirectory: true)) {
            $0.lastPathComponent == "minimap2"
        }
    }

    /// Runs one leaf with `arguments` after its result folder and keeps what it printed.
    static func run(
        _ leaf: String,
        _ resultURL: URL,
        _ arguments: [String] = [],
        in scratch: ImportStreamCapture.Scratch
    ) async throws -> ImportStreamCapture.Output {
        let argv = [resultURL.path] + arguments
        switch leaf {
        case "build-db kraken2":
            let command = try BuildDbCommand.Kraken2Subcommand.parse(argv)
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        case "build-db esviritu":
            let command = try BuildDbCommand.EsVirituSubcommand.parse(argv)
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        case "build-db taxtriage":
            let command = try BuildDbCommand.TaxTriageSubcommand.parse(argv)
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        default:
            throw ValidationError("No build-db leaf named \(leaf)")
        }
    }

    /// The runs whose `--format json` standard output is checked in under
    /// `Tests/Fixtures/cli-events/commands/build-db-<tool>`. `complete-existing` finds the database that a
    /// first run built and keeps it. `failed` names a `--sample-dir` that holds no `classification.kreport`,
    /// a failure whose message Lungfish writes.
    static func cases() -> [ImportStreamCapture.Case] {
        let json = ["--format", "json"]
        return [
            ImportStreamCapture.Case(leaf: "build-db kraken2", name: "complete") { scratch in
                try await run("build-db kraken2", try kraken2Result(in: scratch), json, in: scratch)
            },
            ImportStreamCapture.Case(leaf: "build-db kraken2", name: "complete-existing") { scratch in
                let result = try kraken2Result(in: scratch)
                _ = try await run("build-db kraken2", result, ["--quiet"], in: scratch)
                return try await run("build-db kraken2", result, json, in: scratch)
            },
            ImportStreamCapture.Case(leaf: "build-db kraken2", name: "failed") { scratch in
                let result = try kraken2Result(in: scratch)
                let noReport = result.appendingPathComponent("no-report", isDirectory: true)
                try FileManager.default.createDirectory(at: noReport, withIntermediateDirectories: true)
                return try await run("build-db kraken2", result, ["--sample-dir", noReport.path] + json, in: scratch)
            },
            ImportStreamCapture.Case(leaf: "build-db esviritu", name: "complete") { scratch in
                try await run("build-db esviritu", try esVirituResultWithoutBAMs(in: scratch), json, in: scratch)
            },
            ImportStreamCapture.Case(leaf: "build-db taxtriage", name: "complete") { scratch in
                try await run("build-db taxtriage", try taxTriageResultWithoutBAMs(in: scratch), json, in: scratch)
            },
        ]
    }

    /// The size a cleanup line reports depends on gzip and on the locale's number format, so a
    /// comparison reads the line up to the size and from the closing bracket.
    static func withoutFreedSize(_ lines: [String]) -> [String] {
        let opening = "Removed intermediate files ("
        return lines.map { line in
            guard line.hasPrefix(opening), line.hasSuffix(").") else { return line }
            return opening + "<size>)."
        }
    }

    private static func copyFixture(
        _ name: String,
        to destination: URL,
        dropping shouldDrop: (URL) -> Bool = { _ in false }
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: fixturesFolder.appendingPathComponent(name, isDirectory: true), to: destination)
        let dropped = (fileManager.enumerator(at: destination, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter(shouldDrop)
        for url in dropped where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return destination
    }
}
