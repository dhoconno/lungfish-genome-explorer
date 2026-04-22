// AssemblyOutputNormalizer.swift - Normalize tool-specific assembly outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum AssemblyOutputNormalizer {
    public static func normalize(
        request: AssemblyRunRequest,
        primaryOutputDirectory: URL,
        commandLine: String,
        wallTimeSeconds: TimeInterval,
        assemblerVersion: String? = nil
    ) throws -> AssemblyResult {
        let fm = FileManager.default

        let contigsPath: URL
        let graphPath: URL?
        let scaffoldsPath: URL?
        let paramsPath: URL?

        switch request.tool {
        case .spades:
            contigsPath = primaryOutputDirectory.appendingPathComponent("contigs.fasta")
            graphPath = primaryOutputDirectory.appendingPathComponent("assembly_graph.gfa")
            scaffoldsPath = primaryOutputDirectory.appendingPathComponent("scaffolds.fasta")
            paramsPath = primaryOutputDirectory.appendingPathComponent("params.txt")
        case .megahit:
            contigsPath = primaryOutputDirectory.appendingPathComponent("final.contigs.fa")
            graphPath = nil
            scaffoldsPath = nil
            paramsPath = nil
        case .skesa:
            contigsPath = primaryOutputDirectory.appendingPathComponent("contigs.fasta")
            graphPath = nil
            scaffoldsPath = nil
            paramsPath = nil
        case .flye:
            contigsPath = primaryOutputDirectory.appendingPathComponent("assembly.fasta")
            graphPath = primaryOutputDirectory.appendingPathComponent("assembly_graph.gfa")
            scaffoldsPath = nil
            paramsPath = nil
        case .hifiasm:
            let gfaPath = primaryOutputDirectory.appendingPathComponent("\(request.projectName).bp.p_ctg.gfa")
            let fastaPath = primaryOutputDirectory.appendingPathComponent("contigs.fasta")
            if fm.fileExists(atPath: gfaPath.path), !fm.fileExists(atPath: fastaPath.path) {
                try GFASegmentFASTAWriter.writePrimaryContigs(from: gfaPath, to: fastaPath)
            }
            contigsPath = fastaPath
            graphPath = gfaPath
            scaffoldsPath = nil
            paramsPath = nil
        }

        if !fm.fileExists(atPath: contigsPath.path) {
            // Some assemblers can exit successfully without materializing a
            // primary FASTA when no contigs survive. Synthesize an empty file
            // so the completed-with-no-contigs outcome can round-trip through
            // the shared assembly result model and viewers.
            try Data().write(to: contigsPath)
        }

        let statistics = try AssemblyStatisticsCalculator.compute(from: contigsPath)
        let outcome: AssemblyOutcome
        if statistics.contigCount > 0 {
            try FASTAIndexBuilder.buildAndWrite(for: contigsPath)
            outcome = .completed
        } else {
            outcome = .completedWithNoContigs
        }
        let logPath = primaryOutputDirectory.appendingPathComponent("assembly.log")

        return AssemblyResult(
            tool: request.tool,
            readType: request.readType,
            outcome: outcome,
            contigsPath: contigsPath,
            graphPath: existingURL(graphPath),
            logPath: existingURL(logPath),
            assemblerVersion: assemblerVersion,
            commandLine: commandLine,
            outputDirectory: primaryOutputDirectory,
            statistics: statistics,
            wallTimeSeconds: wallTimeSeconds,
            scaffoldsPath: existingURL(scaffoldsPath),
            paramsPath: existingURL(paramsPath)
        )
    }

    private static func existingURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
