// BAMReferenceSnapshotService.swift - Reference lengths and mapped-read counts of a BAM, read with samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "BAMReferenceSnapshotService")

/// The reference lengths and the mapped-read counts samtools reports for one BAM.
public struct BAMReferenceSnapshot: Sendable, Equatable {
    /// Each reference's length, from the header's `@SQ` lines and then from idxstats.
    public let accessionLengths: [String: Int]
    /// Each reference's mapped-read count, from idxstats.
    public let accessionMappedReadCounts: [String: Int]
    /// True when an idxstats attempt exited 0 and gave at least one count.
    public let parsedMappedReads: Bool

    public init(accessionLengths: [String: Int], accessionMappedReadCounts: [String: Int], parsedMappedReads: Bool) {
        self.accessionLengths = accessionLengths
        self.accessionMappedReadCounts = accessionMappedReadCounts
        self.parsedMappedReads = parsedMappedReads
    }
}

/// Reads a BAM's reference lengths and mapped-read counts with samtools, as the TaxTriage viewer does when a row's
/// database stores no reference length (Phase 2.13 lane 13.09, BIO-TT-ROUTES item 2).
public enum BAMReferenceSnapshotService {
    /// Runs `samtools view -H <bam>` for the `@SQ` lengths, which needs no index. Then it tries
    /// `samtools idxstats -X <bam> <index>` when the index file exists and then `samtools idxstats <bam>`, and keeps
    /// the first attempt that exits 0. Its lengths overwrite the header's, and it gives the mapped-read counts. A
    /// reference named `*` and a length at or below 0 are skipped, and output that is not UTF-8 reads as empty.
    ///
    /// Each run blocks the calling thread through ``ToolProcess/runBlocking(_:cancellation:onEvent:onLaunch:)``, so
    /// never call it on the main thread.
    public static func snapshot(bamPath: String, indexPath: String?, samtoolsPath: String) -> BAMReferenceSnapshot {
        let samtoolsURL = URL(fileURLWithPath: samtoolsPath)
        var accessionLengths: [String: Int] = [:]
        var accessionMappedReadCounts: [String: Int] = [:]
        var parsedMappedReads = false

        // 1) Sequence lengths from header (does not require an index).
        if let header = runSamtools(samtoolsURL, ["view", "-H", bamPath]), header.status == 0 {
            for line in header.stdout.components(separatedBy: .newlines) where line.hasPrefix("@SQ") {
                let fields = line.components(separatedBy: "\t")
                var name: String?
                var length: Int?
                for field in fields {
                    if field.hasPrefix("SN:") {
                        name = String(field.dropFirst(3))
                    } else if field.hasPrefix("LN:") {
                        length = Int(field.dropFirst(3))
                    }
                }
                if let name, let length, length > 0 {
                    accessionLengths[name] = length
                }
            }
        }

        // 2) idxstats for mapped read counts (prefer explicit index path when available).
        let fm = FileManager.default
        var idxstatsAttempts: [[String]] = []
        if let indexPath, fm.fileExists(atPath: indexPath) {
            idxstatsAttempts.append(["idxstats", "-X", bamPath, indexPath])
        }
        idxstatsAttempts.append(["idxstats", bamPath])

        for args in idxstatsAttempts {
            guard let result = runSamtools(samtoolsURL, args) else { continue }
            guard result.status == 0 else {
                if !result.stderr.isEmpty {
                    logger.warning("samtools \(args.joined(separator: " "), privacy: .public) failed: \(result.stderr, privacy: .public)")
                }
                continue
            }

            for line in result.stdout.components(separatedBy: .newlines) {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 4 else { continue }
                let ref = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty, ref != "*" else { continue }
                if let length = Int(cols[1]), length > 0 {
                    accessionLengths[ref] = length
                }
                if let mappedReads = Int(cols[2]) {
                    accessionMappedReadCounts[ref] = mappedReads
                    parsedMappedReads = true
                }
            }
            break
        }

        return BAMReferenceSnapshot(
            accessionLengths: accessionLengths,
            accessionMappedReadCounts: accessionMappedReadCounts,
            parsedMappedReads: parsedMappedReads
        )
    }

    /// Runs samtools with `arguments` and returns its raw status (the exit code, or the signal number), with stdout
    /// and stderr decoded as UTF-8, or nil when it could not run. Both streams are read while it runs, so no amount
    /// of either can fill a pipe and stall it.
    private static func runSamtools(
        _ samtoolsURL: URL,
        _ arguments: [String]
    ) -> (status: Int32, stdout: String, stderr: String)? {
        let spec = ToolProcessSpec(
            executableURL: samtoolsURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            label: "samtools \(arguments.first ?? "")"
        )
        do {
            let result = try ToolProcess.runBlocking(spec)
            guard result.outputComplete else {
                logger.warning("samtools \(arguments.joined(separator: " "), privacy: .public) gave incomplete output: \(result.incompleteOutputReason ?? "", privacy: .public)")
                return nil
            }
            return (
                result.status,
                String(data: result.stdout, encoding: .utf8) ?? "",
                String(data: result.stderr, encoding: .utf8) ?? ""
            )
        } catch {
            logger.warning("Failed to run samtools \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
