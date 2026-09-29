// InterruptedAnalysisRunDiscovery.swift - Lists analysis runs that never finished
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

/// Finds analysis result directories whose run never finished and lists them
/// in the Operations Panel as "Interrupted" rows.
///
/// An incomplete directory (one carrying an ``AnalysisRunRecord``) is never
/// shown in the sidebar and is never deleted automatically. On project open it
/// is classified from its record:
///
/// - Producer on this computer and gone (dead PID, or a reused PID): listed.
/// - Recorded by this app process but no running operation tracks it (the run
///   ended without finishing it): listed.
/// - Producer still alive (another app window's run, a `lungfish-cli` run in
///   Terminal): not listed, it is still running.
/// - Recorded on a different computer: not listed and never offered for
///   removal, because its producer cannot be checked from here. It stays
///   hidden (a known limitation for shared projects).
///
/// Listing changes nothing on disk. The row offers Remove Partial Output
/// (after confirmation), Reveal in Finder, Copy CLI Command and View Log.
@MainActor
enum InterruptedAnalysisRunDiscovery {

    struct Candidate: Sendable {
        let directory: URL
        let record: AnalysisRunRecord?
        let sizeOnDiskBytes: Int64
        var scratchDirectories: [URL] = []
        var scratchSizeOnDiskBytes: Int64 = 0
    }

    /// Scans the project and registers its interrupted runs.
    ///
    /// - Returns: IDs of the rows added (already-listed runs are skipped).
    @discardableResult
    static func registerInterruptedRuns(
        in projectURL: URL,
        center: OperationCenter = .shared,
        currentHostName: String = AnalysisRunRecord.currentHostName(),
        processProbe: @escaping AnalysisRunRecord.ProcessProbe = AnalysisRunRecord.probeProcess,
        scratchProcessInspector: @escaping AnalysisRunScratch.ProcessInspector = {
            try OwnedProcessIdentity.inspect(processIdentifier: $0)
        }
    ) async -> [UUID] {
        let candidates = await Task.detached(priority: .utility) {
            let runs = AnalysesFolder.incompleteAnalysisRuns(in: projectURL)
            // Scratch in .tmp/ that each run's gone producer left behind.
            // Scratch whose creating process is alive is never attributed.
            let scratch = AnalysisRunScratch.abandonedScratch(
                for: runs.compactMap { run in
                    run.record.map { AnalysisRunScratch.Run(directory: run.directory, record: $0) }
                },
                in: projectURL,
                processInspector: scratchProcessInspector
            )
            return runs.map { run in
                let scratchDirectories = scratch[run.directory.standardizedFileURL.path] ?? []
                let scratchBytes = scratchDirectories.reduce(Int64(0)) { $0 + AnalysisRunScratch.allocatedSize(of: $1) }
                return Candidate(
                    directory: run.directory,
                    record: run.record,
                    sizeOnDiskBytes: allocatedSize(of: run.directory) + scratchBytes,
                    scratchDirectories: scratchDirectories,
                    scratchSizeOnDiskBytes: scratchBytes
                )
            }
        }.value

        let ownPID = getpid()
        let ownStart = AnalysisRunRecord.startTime(ofProcess: ownPID)
        var registered: [UUID] = []
        for candidate in candidates {
            guard !center.isTrackingAnalysisOutput(candidate.directory) else { continue }
            if let record = candidate.record {
                switch record.liveness(currentHostName: currentHostName, processProbe: processProbe) {
                case .otherHost:
                    continue
                case .running:
                    // Alive: only this process's own untracked runs are orphans.
                    let ownRecord = record.processIdentifier == ownPID
                        && (record.processStartTime == nil || record.processStartTime == ownStart)
                    guard ownRecord else { continue }
                case .interrupted:
                    break
                }
            }
            let run = OperationCenter.InterruptedAnalysisRun(
                directory: candidate.directory,
                record: candidate.record,
                sizeOnDiskBytes: candidate.sizeOnDiskBytes,
                projectURL: projectURL,
                scratchDirectories: candidate.scratchDirectories,
                scratchSizeOnDiskBytes: candidate.scratchSizeOnDiskBytes
            )
            if let id = center.registerInterruptedAnalysisRun(run) {
                registered.append(id)
            }
        }
        return registered
    }

    enum RemovalError: LocalizedError {
        case notInterrupted
        case stillRunning

        var errorDescription: String? {
            switch self {
            case .notInterrupted:
                return "This folder is no longer an interrupted run, so it was left in place."
            case .stillRunning:
                return "An operation is still writing to this folder."
            }
        }
    }

    /// Deletes an interrupted run's partial output and clears its row. The
    /// caller confirms with the user first. A directory that has since been
    /// completed or is tracked by a running operation is never removed.
    ///
    /// The row's scratch folders in `.tmp/` are removed too, each only after
    /// checking again that it is still active scratch of this run whose
    /// creating process is gone. Scratch a live process owns is left alone.
    static func removePartialOutput(
        itemID: UUID,
        center: OperationCenter = .shared,
        scratchProcessInspector: AnalysisRunScratch.ProcessInspector = {
            try OwnedProcessIdentity.inspect(processIdentifier: $0)
        }
    ) throws {
        guard let item = center.items.first(where: { $0.id == itemID }),
              item.state == .interrupted,
              let directory = item.interruptedRunDirectory else {
            throw RemovalError.notInterrupted
        }
        guard !center.isTrackingAnalysisOutput(directory) else { throw RemovalError.stillRunning }
        guard AnalysisRunRecord.isIncomplete(directory) else {
            center.clearItem(id: itemID)
            throw RemovalError.notInterrupted
        }
        let record = AnalysisRunRecord.load(from: directory)
        let projectURL = item.routeContext?.projectURL ?? ProjectTempDirectory.findProjectRoot(directory)
        let scratch: [URL]
        if let record, let projectURL {
            scratch = item.interruptedRunScratchDirectories.filter {
                AnalysisRunScratch.isAbandonedScratch($0, of: record, in: projectURL, processInspector: scratchProcessInspector)
            }
        } else {
            scratch = []
        }
        try FileManager.default.removeItem(at: directory)
        for folder in scratch {
            try FileManager.default.removeItem(at: folder)
        }
        let parent = directory.deletingLastPathComponent()
        if AnalysesFolder.readAnalysisMetadata(from: parent)?.isBatch == true {
            AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(parent)
        }
        center.clearItem(id: itemID)
    }

    nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
