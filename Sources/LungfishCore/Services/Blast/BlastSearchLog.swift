// BlastSearchLog.swift - The field log of BLAST searches, with no reads, path or label in it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastSearchLog")

/// The files a BLAST search shares with every other process on this Mac, each under `<root>/blast/`.
package struct BlastSearchShared: Sendable {
    /// Gives each contact its slot. With none, as a test's service, a contact keeps no spacing.
    package let contactGate: BlastContactGate?
    /// Holds back LGE's own copies on a bad day.
    package let copyGuard: BlastCopyGuard
    /// Takes a line for each search. With none, as a test's service, nothing is written.
    package let searchLog: BlastSearchLog?

    package init(contactGate: BlastContactGate? = nil, copyGuard: BlastCopyGuard = BlastCopyGuard(), searchLog: BlastSearchLog? = nil) {
        self.contactGate = contactGate
        self.copyGuard = copyGuard
        self.searchLog = searchLog
    }

    /// The files under the active managed storage root, or in a debug stand-in run's own state folder.
    package static func managedStorageDefault(environment: [String: String]) -> BlastSearchShared {
        BlastSearchShared(
            contactGate: .managedStorageDefault(environment: environment),
            copyGuard: .managedStorageDefault(environment: environment),
            searchLog: .managedStorageDefault(environment: environment)
        )
    }
}

/// The field log of BLAST searches, `<root>/blast/search-log.tsv`.
///
/// A search adds a line when NCBI first has it and a line at its ending, and the last line of an ID is where it stands.
/// So a search lost is an ID past NCBI's retention with no ending, and the target is none (ARCH-BLAST-RESILIENCE
/// section 6). The seconds to a first READY are what can move ``BlastSearchPolicy/resendInterval``, and the reply bytes
/// are what can show that a long query needs a shorter list (BIO-BLAST-TIES, BLAST-CONTIG-REPLY-SIZE). No line holds a
/// read, a path or a label. A line that cannot be written costs only itself, since the log never holds up a search.
package struct BlastSearchLog: Sendable {
    /// The file's name in the folder that holds what BLAST shares across processes.
    package static let fileName = "search-log.tsv"
    /// The first line of the file.
    package static let header = "at\tsearchID\trids\tcopies\tsecondsToFirstReady\tending\tfailedContacts\treplyBytes"

    private let fileProvider: @Sendable () async -> URL?

    /// A log in `file`.
    package init(file: URL) {
        self.fileProvider = { file }
    }

    private init(fileProvider: @escaping @Sendable () async -> URL?) {
        self.fileProvider = fileProvider
    }

    /// The log under the active managed storage root. A debug build's stand-in run keeps it in its own state folder.
    package static func managedStorageDefault(environment: [String: String]) -> BlastSearchLog {
        BlastSearchLog {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
                .appendingPathComponent(fileName, isDirectory: false)
        }
    }

    /// The line for `file` as it stands at `at`. A search with no ending leaves that column empty.
    package static func line(for file: BlastSearchFile, at: Date, ending: String?, replyBytes: Int?) -> String {
        let sent = file.copies.compactMap(\.rid)
        let firstReady = file.copies.compactMap(\.readyAt).min().map { String(format: "%.1f", $0.timeIntervalSince(file.createdAt)) }
        return [
            at.formatted(.iso8601),
            file.searchID.uuidString,
            sent.joined(separator: ","),
            String(sent.count),
            firstReady ?? "",
            ending ?? "",
            String(file.copies.reduce(0) { $0 + $1.failedContacts }),
            replyBytes.map(String.init) ?? "",
        ].joined(separator: "\t")
    }

    /// Adds `line`, in one write on a file opened to append, so two processes never mix their lines. The header goes
    /// with the first line under a lock on the file itself, tried once, since a second header costs a reader nothing.
    package func append(_ line: String) async {
        guard let url = await fileProvider() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            logger.warning("Could not open the BLAST search log, so this line is lost")
            return
        }
        defer { close(descriptor) }
        let locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        defer { if locked { flock(descriptor, LOCK_UN) } }
        var info = stat()
        let isNew = fstat(descriptor, &info) == 0 && info.st_size == 0
        let bytes = Array("\(isNew ? Self.header + "\n" : "")\(line)\n".utf8)
        if write(descriptor, bytes, bytes.count) != bytes.count {
            logger.warning("Could not write the BLAST search log, so this line is lost")
        }
    }
}
