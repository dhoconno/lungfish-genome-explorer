// MarkdupService.swift - Runs samtools markdup pipeline on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "MarkdupService")

/// Runs the canonical samtools PCR-duplicate-marking pipeline on BAM files.
///
/// Pipeline: `samtools sort -n | fixmate -m | sort | markdup` followed by `samtools index`.
/// The output replaces the input atomically. Idempotent via the `@PG ID:samtools.markdup`
/// header line that `samtools markdup` adds automatically.
public enum MarkdupService {

    /// `samtools view -F` flag mask for a duplicate-fraction *denominator*:
    /// primary reads regardless of mapped status. Excludes unmapped,
    /// secondary and supplementary records so the denominator is a read
    /// count, not an alignment-record count. Previously this used
    /// `0x004` (unmapped only), which double-counted supplementary and
    /// secondary alignments of the same read.
    private static let totalReadsFlagFilter = 0x904 // UNMAP | SECONDARY | SUPPLEMENTARY

    /// `samtools view -F` flag mask for a duplicate-fraction *numerator*:
    /// primary, non-duplicate reads. Previously this used `0x404` (unmapped
    /// + duplicate only), which also counted secondary and supplementary
    /// records as non-duplicate reads.
    private static let nonDuplicateReadsFlagFilter = 0xD04 // UNMAP | DUP | SECONDARY | SUPPLEMENTARY

    // MARK: - Public API

    /// Runs markdup in-place on a single BAM file.
    @discardableResult
    public static func markdup(
        bamURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> MarkdupResult {
        let runClock = ProvenanceRunClock()

        guard FileManager.default.fileExists(atPath: bamURL.path) else {
            throw MarkdupError.fileNotFound(bamURL)
        }

        // Idempotency check
        if !force && isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath) {
            // Ensure the BAM has a current, non-stale index. Previous pipeline
            // steps may have left behind .csi symlinks pointing at deleted files,
            // which would confuse samtools region queries downstream.
            try ensureFreshIndex(bamURL: bamURL, samtoolsPath: samtoolsPath)

            let total = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: totalReadsFlagFilter, samtoolsPath: samtoolsPath)) ?? 0
            let nonDup = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: nonDuplicateReadsFlagFilter, samtoolsPath: samtoolsPath)) ?? 0
            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: true,
                totalReads: total,
                duplicateReads: max(0, total - nonDup),
                durationSeconds: runClock.elapsed
            )
        }

        // Run the pipeline
        let tempBamURL = URL(fileURLWithPath: bamURL.path + ".markdup.tmp")
        let tempBaiURL = URL(fileURLWithPath: tempBamURL.path + ".bai")

        // Clean up any stale temp files from a previous failed run
        try? FileManager.default.removeItem(at: tempBamURL)
        try? FileManager.default.removeItem(at: tempBaiURL)

        do {
            try runPipeline(
                inputPath: bamURL.path,
                outputPath: tempBamURL.path,
                samtoolsPath: samtoolsPath,
                threads: threads
            )

            // Verify the output exists and is non-empty
            guard FileManager.default.fileExists(atPath: tempBamURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: tempBamURL.path),
                  let size = attrs[.size] as? Int, size > 0 else {
                throw MarkdupError.corruptOutput(reason: "output BAM missing or empty at \(tempBamURL.path)")
            }

            try runIndex(bamPath: tempBamURL.path, samtoolsPath: samtoolsPath)

            // Atomic replacement: remove ALL existing index files (both .bai and .csi)
            // before swapping the BAM, so stale indices from a previous pipeline step
            // don't confuse region queries after markdup.
            let existingBaiURL = URL(fileURLWithPath: bamURL.path + ".bai")
            let existingCsiURL = URL(fileURLWithPath: bamURL.path + ".csi")
            try? FileManager.default.removeItem(at: existingBaiURL)
            try? FileManager.default.removeItem(at: existingCsiURL)
            _ = try FileManager.default.replaceItemAt(bamURL, withItemAt: tempBamURL)
            if FileManager.default.fileExists(atPath: tempBaiURL.path) {
                try FileManager.default.moveItem(at: tempBaiURL, to: existingBaiURL)
            }
        } catch {
            // Clean up temp files on failure
            try? FileManager.default.removeItem(at: tempBamURL)
            try? FileManager.default.removeItem(at: tempBaiURL)
            throw error
        }

        // Count reads post-markdup for the result
        let total = try countReads(bamURL: bamURL, accession: nil, flagFilter: totalReadsFlagFilter, samtoolsPath: samtoolsPath)
        let nonDup = try countReads(bamURL: bamURL, accession: nil, flagFilter: nonDuplicateReadsFlagFilter, samtoolsPath: samtoolsPath)

        logger.info("Marked duplicates in \(bamURL.lastPathComponent, privacy: .public): \(total - nonDup)/\(total)")

        return MarkdupResult(
            bamURL: bamURL,
            wasAlreadyMarkduped: false,
            totalReads: total,
            duplicateReads: max(0, total - nonDup),
            durationSeconds: runClock.elapsed
        )
    }

    /// Runs markdup on every `.bam` file in a directory tree.
    @discardableResult
    public static func markdupDirectory(
        _ dirURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> [MarkdupResult] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [MarkdupResult] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "bam" else { continue }
            let result = try markdup(
                bamURL: fileURL,
                samtoolsPath: samtoolsPath,
                threads: threads,
                force: force
            )
            results.append(result)
        }
        return results
    }

    /// Checks whether a BAM has already been processed by samtools markdup.
    public static func isAlreadyMarkduped(bamURL: URL, samtoolsPath: String) -> Bool {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtoolsPath),
            arguments: ["view", "-H", bamURL.path],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stderr: .discard,
            label: "samtools view -H"
        )
        guard let result = try? ToolProcess.runBlocking(spec), result.isSuccess,
              let header = String(data: result.stdout, encoding: .utf8) else {
            return false
        }
        // samtools 1.23 writes @PG lines with CL: fields; the markdup stage uses
        // "samtools markdup" in its CL: tag rather than a literal ID:samtools.markdup.
        return header.contains("samtools markdup")
    }

    /// Counts reads in a BAM matching a flag filter, optionally restricted to an accession.
    public static func countReads(
        bamURL: URL,
        accession: String?,
        flagFilter: Int,
        samtoolsPath: String
    ) throws -> Int {
        var args = ["view", "-c", "-F", String(flagFilter), bamURL.path]
        if let accession, !accession.isEmpty {
            args.append(accession)
        }
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtoolsPath),
            arguments: args,
            environment: ToolProcessSpec.inheritedEnvironment(),
            label: "samtools view -c"
        )
        let result: ToolProcessResult
        do {
            result = try ToolProcess.runBlocking(spec)
        } catch {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: error.localizedDescription)
        }
        guard result.isSuccess else {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: failureWords(result))
        }
        let output = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(output) ?? 0
    }

    // MARK: - Private Helpers

    /// Runs the four stages as one `ToolProcess` pipeline, each a samtools process of its own with the argv the
    /// shell script gave it. Paths are argv entries, so a `$`, a backtick or a `"` in one cannot be read as
    /// anything else.
    ///
    /// The pipeline keeps what `set -o pipefail` gave the script. A failing stage fails the whole run instead of
    /// being masked by a successful exit from the last stage. Every stage runs to its end, as the stages of the
    /// shell pipe did, so the failure carries each stage's own stderr in stage order. Nothing feeds the first
    /// stage's stdin, and the last stage's stdout is discarded, since `markdup` writes its BAM to `outputPath`.
    private static func runPipeline(
        inputPath: String,
        outputPath: String,
        samtoolsPath: String,
        threads: Int
    ) throws {
        let samtools = URL(fileURLWithPath: samtoolsPath)
        let threadCount = String(threads)
        func stage(_ arguments: [String], stdout: ToolProcessOutput = .capture()) -> ToolProcessSpec {
            ToolProcessSpec(
                executableURL: samtools,
                arguments: arguments,
                environment: ToolProcessSpec.inheritedEnvironment(),
                stdout: stdout,
                label: "samtools \(arguments[0])"
            )
        }
        let stages = [
            stage(["sort", "-n", "-@", threadCount, inputPath]),
            stage(["fixmate", "-m", "-", "-"]),
            stage(["sort", "-@", threadCount, "-"]),
            stage(["markdup", "-", outputPath], stdout: .discard),
        ]
        let result: ToolPipelineResult
        do {
            result = try ToolProcess.startPipeline(stages, failurePolicy: .runToCompletion).waitBlocking()
        } catch {
            throw MarkdupError.pipelineFailed(stage: "launch", stderr: error.localizedDescription)
        }
        guard result.isSuccess else {
            throw MarkdupError.pipelineFailed(
                stage: "markdup-pipeline",
                stderr: result.stages.map { failureWords($0) }.joined()
            )
        }
    }

    /// Ensures a BAM file has a current `.bai` index, removing any stale
    /// `.bai`/`.csi` files first. Used on the idempotent markdup path where
    /// the BAM is already marked but may have dangling index files from a
    /// previous pipeline step (e.g., a `.csi` symlink to a deleted directory).
    private static func ensureFreshIndex(bamURL: URL, samtoolsPath: String) throws {
        let fm = FileManager.default
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")

        // Check whether the existing .bai is usable. Any read failure (stale
        // symlink, missing target, corrupt index) triggers a rebuild.
        let baiHealthy: Bool = {
            guard fm.fileExists(atPath: baiURL.path) else { return false }
            // Probe by reading one byte. If the target of a symlink is gone,
            // this throws even though fileExists returned true (via link).
            let attrs = try? fm.attributesOfItem(atPath: baiURL.path)
            let size = (attrs?[.size] as? Int) ?? 0
            return size > 0
        }()

        if !baiHealthy {
            // Remove any dangling index files (including symlinks) and regenerate
            try? fm.removeItem(at: baiURL)
            try? fm.removeItem(at: csiURL)
            try runIndex(bamPath: bamURL.path, samtoolsPath: samtoolsPath)
            return
        }

        // .bai looks fine; still remove any stale .csi that might shadow it
        // during samtools region queries.
        if fm.fileExists(atPath: csiURL.path) {
            try? fm.removeItem(at: csiURL)
        }
    }

    /// Runs `samtools index` on a BAM file.
    private static func runIndex(bamPath: String, samtoolsPath: String) throws {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtoolsPath),
            arguments: ["index", bamPath],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: .discard,
            label: "samtools index"
        )
        let result: ToolProcessResult
        do {
            result = try ToolProcess.runBlocking(spec)
        } catch {
            throw MarkdupError.indexFailed(stderr: error.localizedDescription)
        }
        guard result.isSuccess else {
            throw MarkdupError.indexFailed(stderr: failureWords(result))
        }
    }

    /// The words of a run that did not succeed. They are its stderr, or the reason its output is incomplete
    /// when it exited 0.
    private static func failureWords(_ result: ToolProcessResult) -> String {
        if result.status == 0, let reason = result.incompleteOutputReason { return reason }
        return String(data: result.stderr, encoding: .utf8) ?? ""
    }
}
