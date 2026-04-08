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

    // MARK: - Public API

    /// Runs markdup in-place on a single BAM file.
    @discardableResult
    public static func markdup(
        bamURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> MarkdupResult {
        let start = Date()

        guard FileManager.default.fileExists(atPath: bamURL.path) else {
            throw MarkdupError.fileNotFound(bamURL)
        }

        // Idempotency check
        if !force && isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath) {
            // Ensure the BAM has a current, non-stale index. Previous pipeline
            // steps may have left behind .csi symlinks pointing at deleted files,
            // which would confuse samtools region queries downstream.
            try ensureFreshIndex(bamURL: bamURL, samtoolsPath: samtoolsPath)

            let total = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath)) ?? 0
            let nonDup = (try? countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath)) ?? 0
            return MarkdupResult(
                bamURL: bamURL,
                wasAlreadyMarkduped: true,
                totalReads: total,
                duplicateReads: max(0, total - nonDup),
                durationSeconds: Date().timeIntervalSince(start)
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
        let total = try countReads(bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath)
        let nonDup = try countReads(bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath)

        logger.info("Marked duplicates in \(bamURL.lastPathComponent, privacy: .public): \(total - nonDup)/\(total)")

        return MarkdupResult(
            bamURL: bamURL,
            wasAlreadyMarkduped: false,
            totalReads: total,
            duplicateReads: max(0, total - nonDup),
            durationSeconds: Date().timeIntervalSince(start)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["view", "-H", bamURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let header = String(data: data, encoding: .utf8) else {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        var args = ["view", "-c", "-F", String(flagFilter), bamURL.path]
        if let accession, !accession.isEmpty {
            args.append(accession)
        }
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw MarkdupError.pipelineFailed(stage: "count", stderr: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.pipelineFailed(stage: "count", stderr: stderr)
        }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(output) ?? 0
    }

    // MARK: - Private Helpers

    /// Runs the 4-stage pipeline via /bin/sh -c to use native shell piping.
    private static func runPipeline(
        inputPath: String,
        outputPath: String,
        samtoolsPath: String,
        threads: Int
    ) throws {
        let cmd = """
        "\(samtoolsPath)" sort -n -@ \(threads) "\(inputPath)" | \
        "\(samtoolsPath)" fixmate -m - - | \
        "\(samtoolsPath)" sort -@ \(threads) - | \
        "\(samtoolsPath)" markdup - "\(outputPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MarkdupError.pipelineFailed(stage: "launch", stderr: error.localizedDescription)
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.pipelineFailed(stage: "markdup-pipeline", stderr: stderr)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["index", bamPath]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MarkdupError.indexFailed(stderr: error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw MarkdupError.indexFailed(stderr: stderr)
        }
    }
}
