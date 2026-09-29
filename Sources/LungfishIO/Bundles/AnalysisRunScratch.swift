// AnalysisRunScratch.swift - Scratch folders an interrupted analysis run left in .tmp
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Finds the project scratch (`<project>/.tmp/<prefix><UUID>/`) that an
/// interrupted analysis run left behind.
///
/// Every producer allocates project scratch through
/// ``ProjectTempDirectory/create(prefix:in:)``, which writes an
/// ``OwnedWorkDirectoryMarker`` naming the creating process (PID, start time,
/// boot session). The ``AnalysisRunRecord`` names the same process (and any
/// `lungfish-cli` child that joined the run, see
/// ``AnalysisRunRecord/participants``). So the run's scratch is found without
/// any producer registering it:
///
/// - the marker is still `active` (the run never finished with it),
/// - its creating process is one of the run's producer processes, and
/// - that process is gone. Scratch whose creator is alive is never attributed,
///   so a live run's scratch is never offered for removal.
///
/// When one dead process left several interrupted runs (for example two runs
/// in flight when the app quit), each scratch folder goes to the run that
/// started most recently before the folder was created.
public enum AnalysisRunScratch {

    public typealias ProcessInspector = @Sendable (Int32) throws -> OwnedProcessIdentity?

    /// An interrupted run to match scratch against.
    public struct Run: Sendable {
        public let directory: URL
        public let record: AnalysisRunRecord

        public init(directory: URL, record: AnalysisRunRecord) {
            self.directory = directory
            self.record = record
        }
    }

    /// How much earlier than its run a scratch folder may be created and
    /// still belong to it (clock granularity and setup order).
    public static let creationSlack: TimeInterval = 60

    /// Scratch folders per run directory (keyed by standardized path).
    public static func abandonedScratch(
        for runs: [Run],
        in projectURL: URL,
        processInspector: ProcessInspector = { try OwnedProcessIdentity.inspect(processIdentifier: $0) }
    ) -> [String: [URL]] {
        guard !runs.isEmpty else { return [:] }
        let root = ProjectTempDirectory.tempRoot(for: projectURL)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey],
            options: []
        ) else { return [:] }

        var result: [String: [URL]] = [:]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let marker = abandonedMarker(of: child, projectURL: projectURL, processInspector: processInspector)
            else { continue }
            let owners = runs.filter { run in
                run.record.producerProcesses.contains { matches(marker, $0) }
            }
            guard !owners.isEmpty else { continue }
            let created = (try? child.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            let owner = owners
                .filter { $0.record.startedAt <= created.addingTimeInterval(creationSlack) }
                .max { $0.record.startedAt < $1.record.startedAt }
                ?? owners.min { $0.record.startedAt < $1.record.startedAt }
            guard let owner else { continue }
            result[owner.directory.standardizedFileURL.path, default: []].append(child)
        }
        return result
    }

    /// Whether `url` is still scratch that `record`'s run abandoned. Checked
    /// again right before removal, so a folder whose creator is alive, or
    /// that changed hands, is left alone.
    public static func isAbandonedScratch(
        _ url: URL,
        of record: AnalysisRunRecord,
        in projectURL: URL,
        processInspector: ProcessInspector = { try OwnedProcessIdentity.inspect(processIdentifier: $0) }
    ) -> Bool {
        let root = ProjectTempDirectory.tempRoot(for: projectURL).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == root,
              let marker = abandonedMarker(of: url, projectURL: projectURL, processInspector: processInspector)
        else { return false }
        return record.producerProcesses.contains { matches(marker, $0) }
    }

    private static func matches(_ marker: OwnedWorkDirectoryMarker, _ process: AnalysisRunRecord.Participant) -> Bool {
        guard marker.processIdentifier == process.processIdentifier else { return false }
        guard let start = process.processStartTime else { return true }
        return marker.processStartTime == start
    }

    /// The marker of an active scratch folder whose creating process is gone.
    private static func abandonedMarker(
        of url: URL,
        projectURL: URL,
        processInspector: ProcessInspector
    ) -> OwnedWorkDirectoryMarker? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let marker = try? OwnedWorkDirectoryMarkerStore.load(from: url, expectedProjectURL: projectURL),
              marker.state == .active,
              !marker.keepIntermediates
        else { return nil }
        let live: OwnedProcessIdentity?
        do {
            live = try processInspector(marker.processIdentifier)
        } catch {
            return nil // Cannot prove the creator is gone: fail closed.
        }
        if let live, marker.matchesProcessIdentity(live) { return nil }
        return marker
    }

    /// Allocated bytes of the files under `url`.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
