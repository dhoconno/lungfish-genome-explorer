// BlastSearchStore.swift - The files of one BLAST search in its result folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Why a search file could not be read. Each case's words say what happened and what to try next.
package enum BlastSearchStoreError: Error, LocalizedError, Equatable {
    case noSearch(folder: String)
    case unreadable(folder: String, reason: String)
    case newerSchema(found: Int)

    package var errorDescription: String? {
        switch self {
        case .noSearch(let folder):
            "No BLAST search is saved in \(folder). Choose the folder that holds \(BlastSearchFile.fileName)."
        case .unreadable(let folder, let reason):
            "The BLAST search in \(folder) could not be read: \(reason). LGE left the file as it is."
        case .newerSchema(let found):
            "This BLAST search was saved by a newer LGE (version \(found) of the file). LGE left it as it is, so open it with that LGE or a later one."
        }
    }
}

/// The files of one BLAST search in its result folder, each written through ``DurableReplace``.
///
/// Any process may read them, and only the process that advances the search writes them (ARCH-BLAST-RESILIENCE
/// section 1). The folder moves, copies and deletes with its project.
package struct BlastSearchStore: Sendable {
    package let folder: URL

    package init(folder: URL) {
        self.folder = folder
    }

    private var fileURL: URL {
        folder.appendingPathComponent(BlastSearchFile.fileName, isDirectory: false)
    }

    private var repliesURL: URL {
        folder.appendingPathComponent(BlastSearchFile.repliesFolderName, isDirectory: true)
    }

    // MARK: The search file

    /// Reads the search file. A read runs no recovery, so a resume calls ``recoverInterruptedSwap()`` first.
    package func load() throws -> BlastSearchFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            throw BlastSearchStoreError.noSearch(folder: folder.path)
        } catch {
            throw BlastSearchStoreError.unreadable(folder: folder.path, reason: error.localizedDescription)
        }
        guard !data.isEmpty else { throw BlastSearchStoreError.noSearch(folder: folder.path) }
        struct Version: Decodable { let schemaVersion: Int }
        do {
            let found = try BlastSubmissionRecord.decoder.decode(Version.self, from: data).schemaVersion
            guard found <= BlastSearchFile.currentSchemaVersion else {
                throw BlastSearchStoreError.newerSchema(found: found)
            }
            return try BlastSubmissionRecord.decoder.decode(BlastSearchFile.self, from: data)
        } catch let error as BlastSearchStoreError {
            throw error
        } catch {
            throw BlastSearchStoreError.unreadable(folder: folder.path, reason: error.localizedDescription)
        }
    }

    /// Whether the folder holds a search that has not ended.
    package func holdsALiveSearch() -> Bool {
        guard let file = try? load() else { return false }
        return !file.state.isEnding
    }

    /// Makes the search file durable.
    package func save(_ file: BlastSearchFile) throws {
        try DurableReplace.replace(BlastSubmissionRecord.encoder.encode(file), named: BlastSearchFile.fileName, in: folder)
    }

    /// Puts the search file back when an ExFAT swap was cut short and left the name missing or empty. A resume comes
    /// before any project open, which is what otherwise runs this (`EXTERNAL-VOLUMES.md`).
    package func recoverInterruptedSwap() {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard size == nil || size == 0 else { return }
        PortableRename.recoverInterruptedSwaps(underProject: folder, maximumDepth: 1)
    }

    // MARK: The form

    /// Makes the Put body durable and returns its digest.
    package func saveForm(_ form: Data) throws -> String {
        try DurableReplace.replace(form, named: BlastSearchFile.formFileName, in: folder)
        return Self.digest(of: form)
    }

    package func loadForm() throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(BlastSearchFile.formFileName, isDirectory: false))
    }

    // MARK: Replies

    /// Makes a reply durable before anything reads it, and returns its file name.
    package func saveReply(_ reply: Data, rid: String) throws -> String {
        let name = "\(rid).reply"
        try FileManager.default.createDirectory(at: repliesURL, withIntermediateDirectories: true)
        try DurableReplace.replace(reply, named: name, in: repliesURL)
        return name
    }

    package func loadReply(named name: String) -> Data? {
        try? Data(contentsOf: repliesURL.appendingPathComponent(name, isDirectory: false))
    }

    /// Removes the replies once the record and its sidecar are durable. One left behind costs only its bytes.
    package func removeReplies() {
        try? FileManager.default.removeItem(at: repliesURL)
    }

    /// The lower-case hex SHA-256 of `data`.
    package static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
