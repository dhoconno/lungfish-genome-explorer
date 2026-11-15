// SalmonQuantRoute+Reads.swift - A sample's reads, its trim call and its salmon call (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What one salmon quant asks of the Mac (SPIKE-SALMON, the quant rows of its need table).
enum SalmonQuantNeed {
    static let peakMemoryBytes: Int64 = 6_445_798_776
    static let memoryBasis = "peak memory footprint of salmon 2.11.0 quant -l A -p 8 on SRR896743 against GRCh38 with ERCC92, "
        + "SPIKE-SALMON 2026-11-14"
    static let quantDiskBytes: Int64 = 1_077_186_560
    static let diskBasis = "free-disk drop of salmon 2.11.0 quant on SRR23580170 (71.9 M pairs), SPIKE-SALMON 2026-11-14, "
        + "plus the plain R1 and R2 files written from the largest interleaved file, four times its gzip size"

    static func need(splitBytes: Int64, diskFolder: URL) -> RunFitNeed {
        RunFitNeed(
            peakMemoryBytes: peakMemoryBytes, memoryBasis: memoryBasis,
            freeDiskBytes: RunFitNeed.bytes(splitBytes, times: 1, plus: quantDiskBytes), diskBasis: diskBasis,
            diskFolder: diskFolder)
    }
}

extension SalmonQuantRoute {
    /// One bundle's reads as salmon takes them: mate pairs, or single reads, never both.
    struct SampleReads: Sendable {
        var id: String
        var bundle: URL
        var pairs: [ReadSetMatePair]
        var singles: [URL]
        /// The files the plan hands over, whose sidecars hold the import's record.
        var payloads: [URL]
        /// The bytes a split of interleaved pairs writes, estimated from the files.
        var splitBytes: Int64
    }

    /// Plans the bundle as a tool that pairs reads only when every fragment is a pair, and refuses a layout salmon cannot
    /// count as one sample before any process starts.
    func reads(of bundle: URL, resolver: ReadSetResolver) async throws -> SampleReads {
        let plan = try await resolver.plan(for: bundle, capability: .pairsOnlyWhenAllPaired)
        let name = bundle.lastPathComponent
        guard !plan.sampleHoldsPairsAndSingleReads, plan.singleReadReason == nil else {
            throw SalmonQuantError.layout(
                bundle: name, reason: "holds read pairs and single reads, which one salmon run cannot count as one sample")
        }
        guard plan.runs.count == 1, let run = plan.runs.first, run.mixedStreams.isEmpty,
              run.matePairs.isEmpty != run.singleReads.isEmpty else {
            throw SalmonQuantError.layout(bundle: name, reason: "holds no reads salmon can take as one sample")
        }
        var split: Int64 = 0
        for pair in run.matePairs {
            if case .interleaved(let url) = pair.files {
                split += url.fileSizeBytes * (url.pathExtension.lowercased() == "gz" ? 4 : 1)
            }
        }
        return SampleReads(
            id: bundle.deletingPathExtension().lastPathComponent, bundle: bundle, pairs: run.matePairs,
            singles: run.singleReads.map(\.url), payloads: run.executionURLs, splitBytes: split)
    }

    /// Splits an interleaved pair into plain R1 and R2 files, checking each pair by name.
    func split(_ interleaved: URL, into folder: URL) throws -> (r1: URL, r2: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("reads_1.fastq"), r2 = folder.appendingPathComponent("reads_2.fastq")
        guard FileManager.default.createFile(atPath: r1.path, contents: nil),
              FileManager.default.createFile(atPath: r2.path, contents: nil) else {
            throw SalmonQuantError.invalidRequest("Lungfish could not write the reads into \(folder.path).")
        }
        let one = try FileHandle(forWritingTo: r1), two = try FileHandle(forWritingTo: r2)
        defer {
            try? one.close()
            try? two.close()
        }
        _ = try FASTQPairInterleaver.deinterleave(interleaved: interleaved, r1: one, r2: two)
        return (r1, r2)
    }

    struct SampleRun: Sendable {
        var folder: SalmonQuantFolder
        var steps: [ProvenanceStep]
    }

    /// The sample's trim calls when asked, then its one salmon call and the read of the folder salmon wrote.
    func quantify(
        _ sample: SampleReads, number: Int, request: SalmonQuantRequest, index: SalmonIndexOutcome, salmonVersion: String,
        trimVersion: String?, work: URL
    ) async throws -> SampleRun {
        try Task.checkCancellation()
        let folder = work.appendingPathComponent("sample-\(number)", isDirectory: true)
        var r1s: [URL] = [], r2s: [URL] = []
        for (n, pair) in sample.pairs.enumerated() {
            switch pair.files {
            case .separate(let r1, let r2):
                r1s.append(r1)
                r2s.append(r2)
            case .interleaved(let url):
                let files = try split(url, into: folder.appendingPathComponent("split-\(n)", isDirectory: true))
                r1s.append(files.r1)
                r2s.append(files.r2)
            }
        }
        var singles = sample.singles
        var steps: [ProvenanceStep] = []
        if case .trimGalore(let polyG) = request.trim, let trimVersion {
            let trimmed = try await trim(
                pairs: Array(zip(r1s, r2s)), singles: singles, polyG: polyG, version: trimVersion, sample: sample.id,
                into: folder.appendingPathComponent("trim", isDirectory: true))
            (r1s, r2s, singles) = (trimmed.r1s, trimmed.r2s, trimmed.singles)
            steps += trimmed.steps
        }
        let output = folder.appendingPathComponent("quant", isDirectory: true)
        var arguments = ["quant", "-i", index.indexURL.path, "-l", "A"]
        arguments += r1s.isEmpty ? ["-r"] + singles.map(\.path) : ["-1"] + r1s.map(\.path) + ["-2"] + r2s.map(\.path)
        arguments += ["-p", String(request.threads), "-o", output.path]
        let started = Date()
        let result = try await runner.run(.salmon, arguments: arguments)
        guard result.isSuccess else {
            throw SalmonQuantError.toolFailed(tool: "salmon", sample: sample.id, status: Int(result.exitCode), stderr: result.stderr)
        }
        var read = try SalmonQuantFolderReader.read(folder: output)
        read.sample = sample.id
        steps.append(ProvenanceStep(
            toolName: "salmon", toolVersion: salmonVersion, argv: ["salmon"] + arguments,
            resolvedOptions: recordLines(for: sample, trim: request.trim, trimVersion: trimVersion), exitStatus: 0,
            wallTimeSeconds: Date().timeIntervalSince(started), startedAt: started, completedAt: Date(),
            managedToolID: ManagedToolID(rawValue: "salmon")))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name != "quant" {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return SampleRun(folder: read, steps: steps)
    }

    /// One Trim Galore call a pair and one for the single reads, each passing the poly-G setting (ADJ-ROUTE item 1).
    func trim(
        pairs: [(URL, URL)], singles: [URL], polyG: Bool, version: String, sample: String, into folder: URL
    ) async throws -> (r1s: [URL], r2s: [URL], singles: [URL], steps: [ProvenanceStep]) {
        var r1s: [URL] = [], r2s: [URL] = [], kept: [URL] = [], steps: [ProvenanceStep] = []
        var calls: [(files: [URL], paired: Bool)] = pairs.map { ([$0.0, $0.1], true) }
        if !singles.isEmpty { calls.append((singles, false)) }
        for (n, call) in calls.enumerated() {
            let out = folder.appendingPathComponent("call-\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let arguments = [polyG ? "--poly_g" : "--no_poly_g"] + (call.paired ? ["--paired"] : []) + ["-o", out.path]
                + call.files.map(\.path)
            let started = Date()
            let result = try await runner.run(.trimGalore, arguments: arguments)
            guard result.isSuccess else {
                throw SalmonQuantError.toolFailed(tool: "trim_galore", sample: sample, status: Int(result.exitCode), stderr: result.stderr)
            }
            var outputs: [URL] = []
            for (m, file) in call.files.enumerated() {
                let name = Self.trimmedName(file, mate: call.paired ? m + 1 : nil)
                guard FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path) else {
                    throw SalmonQuantError.trimOutputMissing(sample: sample, file: name)
                }
                outputs.append(out.appendingPathComponent(name))
            }
            if call.paired {
                r1s.append(outputs[0])
                r2s.append(outputs[1])
            } else {
                kept += outputs
            }
            steps.append(ProvenanceStep(
                toolName: "trim_galore", toolVersion: version, argv: ["trim_galore"] + arguments,
                resolvedOptions: ["sample": .string(sample), "polyG": .string(SalmonQuantRecordLines.trimming(.trimGalore(polyG: polyG), version: version))],
                exitStatus: 0, wallTimeSeconds: Date().timeIntervalSince(started), startedAt: started, completedAt: Date(),
                managedToolID: ManagedToolID(rawValue: "trim_galore")))
        }
        return (r1s, r2s, kept, steps)
    }

    /// The name Trim Galore gives its output of `file`: `<stem>_val_<mate>.fq` for a pair, `<stem>_trimmed.fq` otherwise.
    static func trimmedName(_ file: URL, mate: Int?) -> String {
        var name = file.lastPathComponent, gz = ""
        if name.hasSuffix(".gz") {
            name.removeLast(3)
            gz = ".gz"
        }
        if let ext = [".fastq", ".fq"].first(where: name.hasSuffix) { name.removeLast(ext.count) }
        return mate.map { "\(name)_val_\($0).fq\(gz)" } ?? "\(name)_trimmed.fq\(gz)"
    }
}
