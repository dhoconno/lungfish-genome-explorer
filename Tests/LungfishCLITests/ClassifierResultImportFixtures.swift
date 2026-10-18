// ClassifierResultImportFixtures.swift - Small Kraken2, EsViritu and TaxTriage results with a dotted sample id
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The results that the `import kraken2`, `import esviritu` and `import taxtriage` tests import (Phase 2.12 lane
/// 12.04). Each carries the dotted sample id `S1.2024`, so a test sees whether a name is read whole (BIO 5). They
/// come from `Tests/Fixtures/kraken2-mini`, `esviritu-mini` and `taxtriage-mini`, without the BAMs.
enum ClassifierResultImportFixtures {
    /// The sample id every fixture carries.
    static let sampleID = "S1.2024"

    /// A non-English locale for a child process (X12).
    static let nonEnglishLocale = ["LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8"]

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

    /// `S1.2024.kraken`, a per-read output of `lines` classified reads, which takes the import seconds to compact.
    static func largeKraken2Output(in root: URL, lines: Int) throws -> URL {
        let output = root.appendingPathComponent("\(sampleID).kraken")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var chunk = Data()
        for index in 0..<lines {
            chunk.append(contentsOf: Array("C\tread\(index)\t2697049\t150\t2697049:116\n".utf8))
            if chunk.count > 4_000_000 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
        return output
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

    /// Adds a sparse file of `gigabytes` GB to `folder`. It takes no disk space, a copy clones it, and hashing it
    /// takes seconds, which holds an import at work.
    static func addLargeSparseFile(to folder: URL, gigabytes: UInt64 = 4) throws {
        let file = folder.appendingPathComponent("hold.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: gigabytes * 1_073_741_824)
    }

    /// The result folders an import made in `imports`, whatever their prefix.
    static func resultFolders(in imports: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
