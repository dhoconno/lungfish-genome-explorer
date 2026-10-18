// ClassifierImportAppFixtures.swift - Kraken2, EsViritu and TaxTriage results with a dotted sample id, for the app tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Darwin
import Foundation
@testable import LungfishCLI

/// The results the app's classifier result import tests use (Phase 2.12 lane 12.04), the same as
/// `ClassifierResultImportFixtures` of the CLI tests. Each carries the dotted sample id `S1.2024` (BIO 5) and
/// comes from `Tests/Fixtures/kraken2-mini`, `esviritu-mini` or `taxtriage-mini` without the BAMs.
enum ClassifierImportAppFixtures {
    static let sampleID = "S1.2024"

    static var fixturesFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// `S1.2024.kreport`, the kreport of `kraken2-mini/SRR35517702`.
    static func kraken2Report(in root: URL) throws -> URL {
        let report = root.appendingPathComponent("\(sampleID).kreport")
        try FileManager.default.copyItem(
            at: fixturesFolder.appendingPathComponent("kraken2-mini/SRR35517702/classification.kreport"),
            to: report
        )
        return report
    }

    /// `S1.2024/`, the three tables of `esviritu-mini/SRR35517702` named for the dotted sample id.
    static func esVirituResult(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(sampleID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = fixturesFolder.appendingPathComponent("esviritu-mini/SRR35517702", isDirectory: true)
        for suffix in ["detected_virus.info.tsv", "detected_virus.assembly_summary.tsv", "virus_coverage_windows.tsv"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent("SRR35517702.\(suffix)"),
                to: folder.appendingPathComponent("\(sampleID).\(suffix)")
            )
        }
        return folder
    }

    /// `run.2024/`, `taxtriage-mini` without `minimap2`, whose top report is named for the dotted sample id.
    static func taxTriageResult(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("run.2024", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.copyItem(at: fixturesFolder.appendingPathComponent("taxtriage-mini", isDirectory: true), to: folder)
        try fileManager.removeItem(at: folder.appendingPathComponent("minimap2", isDirectory: true))
        try fileManager.moveItem(
            at: folder.appendingPathComponent("top/SRR35517702.top_report.tsv"),
            to: folder.appendingPathComponent("top/\(sampleID).top_report.tsv")
        )
        return folder
    }

    /// Adds a 4 GB sparse file to `folder`. It takes no disk space, a copy clones it, and hashing it takes
    /// seconds, which holds an import at work.
    static func addLargeSparseFile(to folder: URL) throws {
        let file = folder.appendingPathComponent("hold.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 4 * 1_073_741_824)
    }

    /// Every regular file under `folder`, sorted by path.
    static func regularFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// Runs `lungfish-cli <argv>` in process, as the route's runner launches it, with standard output sent to a file
    /// under `root`, and returns the error the command threw, if any, and the lines it printed, which hold its events
    /// under `--format json`. The record tests use it as the vehicle of the import service since lane 12.06 removed
    /// the app's helper mode.
    @MainActor
    static func runCLI(_ argv: [String], in root: URL) async throws -> (failure: (any Error)?, lines: [String]) {
        let file = root.appendingPathComponent("standard-output-\(UUID().uuidString).capture")
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard saved >= 0, descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)
        var failure: (any Error)?
        do { try await runParsed(argv) } catch { failure = error }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: file)
        return (failure, text.split(separator: "\n").map(String.init))
    }

    /// Parses `argv` with the root command, as `lungfish-cli` does, and runs the leaf it names.
    nonisolated private static func runParsed(_ argv: [String]) async throws {
        guard var command = try LungfishCLI.parseAsRoot(argv) as? AsyncParsableCommand else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "\(argv) names no async leaf"])
        }
        try await command.run()
    }
}
