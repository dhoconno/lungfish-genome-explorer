// ConformanceFixtures.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Shared helpers for the tool-version and pipeline conformance suites: fixture
// path resolution, scratch directories, the bundled dependency manifest, the
// per-tool version-check command table, and the installed Kraken2 viral DB.

import Foundation
@testable import LungfishWorkflow

enum ConformanceFixtures {
    /// Root of the shared fixtures tree (`Tests/Fixtures`), resolved relative to
    /// this source file so it works regardless of the current working directory.
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Conformance/
            .deletingLastPathComponent()   // LungfishWorkflowTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/Fixtures")
    }

    /// The shared SARS-CoV-2 fixture directory (`Tests/Fixtures/sarscov2`).
    static var sarscov2: URL {
        fixturesRoot.appendingPathComponent("sarscov2")
    }

    /// Resolves a path under `Tests/Fixtures/` for the given relative path.
    static func fixture(_ relative: String) -> URL {
        fixturesRoot.appendingPathComponent(relative)
    }

    /// Creates a unique scratch directory under the system temp directory. The
    /// caller is responsible for removing it (e.g. in `tearDown`).
    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-conformance-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The bundled dependency manifest (`third-party-tools-lock.json`).
    static func manifest() throws -> ManagedToolLock {
        try ManagedToolLock.loadFromBundle()
    }

    /// The installed Kraken2 "Viral" database directory, if ready.
    ///
    /// Returns `nil` when the database is not registered, not `.ready`, or its
    /// directory is missing `hash.k2d` -- callers route that through
    /// `ToolAvailability.requireDatabase` to skip or fail depending on
    /// `LUNGFISH_REQUIRE_TOOLS`.
    static func viralKrakenDB() async throws -> URL? {
        try await MetagenomicsDatabaseRegistry.shared.loadIfNeeded()
        guard let db = try await MetagenomicsDatabaseRegistry.shared.database(named: "Viral"),
              db.status == .ready,
              let path = db.path else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent("hash.k2d").path) else {
            return nil
        }
        return path
    }

    /// The version-check command for a manifest tool, keyed by tool id (the
    /// manifest's `tools[].id` / `packTools[].id`, e.g. "samtools", "iqtree").
    ///
    /// Falls back to `<primary executable> --version` using the manifest's
    /// declared executables when the tool id has no entry here.
    static func versionCommand(for toolID: String) -> (executable: String, arguments: [String]) {
        switch toolID {
        case "nextflow": return ("nextflow", ["-version"])
        case "snakemake": return ("snakemake", ["--version"])
        case "bbtools": return ("reformat.sh", ["--version"])
        case "fastp": return ("fastp", ["--version"])
        case "deacon": return ("deacon", ["--version"])
        case "samtools": return ("samtools", ["--version"])
        case "bcftools": return ("bcftools", ["--version"])
        case "htslib": return ("bgzip", ["--version"])
        case "seqkit": return ("seqkit", ["version"])
        case "cutadapt": return ("cutadapt", ["--version"])
        case "trim_galore", "trim-galore": return ("trim_galore", ["--version"])
        case "vsearch": return ("vsearch", ["--version"])
        case "pigz": return ("pigz", ["--version"])
        case "sra-tools": return ("fasterq-dump", ["--version"])
        case "ucsc-bedgraphtobigwig": return ("bedGraphToBigWig", [])
        case "pysam": return ("python", ["-c", "import pysam;print(pysam.__version__)"])
        case "openpyxl": return ("python", ["-c", "import openpyxl;print(openpyxl.__version__)"])
        case "minimap2": return ("minimap2", ["--version"])
        case "bwa-mem2": return ("bwa-mem2", ["version"])
        case "bowtie2": return ("bowtie2", ["--version"])
        case "savont": return ("savont", ["--version"])
        case "blast": return ("blastn", ["-version"])
        case "lofreq": return ("lofreq", ["version"])
        case "ivar": return ("ivar", ["version"])
        case "medaka": return ("medaka", ["--version"])
        case "clair3": return ("run_clair3.sh", ["--version"])
        case "spades": return ("spades.py", ["--version"])
        case "megahit": return ("megahit", ["--version"])
        case "skesa": return ("skesa", ["--version"])
        case "flye": return ("flye", ["--version"])
        case "hifiasm": return ("hifiasm", ["--version"])
        case "mafft": return ("mafft", ["--version"])
        case "iqtree": return ("iqtree3", ["--version"])
        case "kraken2": return ("kraken2", ["--version"])
        case "bracken": return ("bracken", ["-v"])
        case "esviritu": return ("EsViritu", ["--version"])
        case "ribodetector": return ("ribodetector", ["-v"])
        case "freyja": return ("freyja", ["--version"])
        case "gatk4": return ("gatk", ["--version"])
        case "whatshap": return ("whatshap", ["--version"])
        default:
            return (fallbackExecutable(for: toolID), ["--version"])
        }
    }

    /// The primary executable the bundled manifest declares for a tool id, used
    /// as the version-check fallback executable for ids the table above doesn't
    /// cover explicitly. Falls back to the id itself if the manifest has no
    /// matching `tools`/`packTools` entry (e.g. in a unit test that invents a
    /// synthetic id) or declares no executables.
    private static func fallbackExecutable(for toolID: String) -> String {
        let lock = ManagedToolLock.bundled
        if let tool = lock.tools.first(where: { $0.id == toolID }), let first = tool.executables.first {
            return first
        }
        if let packTool = lock.packTools.first(where: { $0.toolID == toolID }), let first = packTool.executables.first {
            return first
        }
        return toolID
    }

    /// True for tools whose version-check command is expected to just run
    /// successfully (usage/help output) rather than contain the pinned version
    /// string -- `ucsc-bedgraphtobigwig` prints usage and can exit non-zero.
    static func skipsVersionMatch(for toolID: String) -> Bool {
        toolID == "ucsc-bedgraphtobigwig"
    }

    /// Whether `text` reports the exact pinned `version` as a standalone
    /// version token, not merely as a substring.
    ///
    /// Plain `contains` gives false positives on short pins: `"2.3"` matches
    /// inside `"2.30"` or `"2.3.0-rc1"`, and `"1.0.0"` would even match inside
    /// an unrelated `"31.0.0"`. This anchors the match so `expected` must be
    /// followed (and preceded) by something that is not part of a longer
    /// version/number token -- i.e. not a digit and not `.` on either side.
    static func textReportsVersion(_ text: String, version expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        let escaped = NSRegularExpression.escapedPattern(for: expected)
        let pattern = "(?<![0-9.])\(escaped)(?![0-9.])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.contains(expected)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
