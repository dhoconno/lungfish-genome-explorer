// ProvenanceSidecarIndex.swift - The provenance sidecars of a project, read once for every lineage walk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import Synchronization

/// The provenance sidecars of each project, keyed by the checksums of the files they produced.
///
/// A lineage walk falls back to this index when a recorded path resolves nothing. Every walk of a
/// project shares one index, so a sidecar is read once while its path, size and modification date
/// hold. The index keeps the record id, the creation date, a digest of the run signature and the
/// produced checksums of each sidecar, never the record itself. Reading those skips the path
/// re-rooting the full reader does, because none of them is a path the walk follows. A walk reads
/// a matched sidecar in full only when it visits it. The FSEvents watcher drops the entries of the
/// sidecars it sees change.
///
/// The walk is synchronous, because the exporter and the CLI call it from synchronous code, so the
/// index keeps its state in a `Mutex` rather than an actor and never holds it across a file read.
public final class ProvenanceSidecarIndex: Sendable {
    /// The index every lineage walk in this process shares.
    public static let shared = ProvenanceSidecarIndex()

    /// A record that produced a checksum, with what a walk needs to choose it before reading it.
    public struct Producer: Sendable, Equatable {
        public let sidecarURL: URL
        public let recordID: UUID
        public let createdAt: Date
    }

    /// The producers of each checksum in one project, as one walk sees them.
    public struct Snapshot: Sendable {
        fileprivate var producers: [Producer] = []
        fileprivate var byChecksum: [String: [Int]] = [:]

        /// The records that produced `checksum`, canonical sidecars first.
        public func producers(ofChecksum checksum: String) -> [Producer] {
            (byChecksum[checksum] ?? []).map { producers[$0] }
        }
    }

    private let state = Mutex(State())
    private let maximumProjects: Int

    /// - Parameter maximumProjects: How many projects keep their entries. Beyond that many, the
    ///   project a walk used least recently is dropped whole.
    public init(maximumProjects: Int = 4) {
        self.maximumProjects = max(1, maximumProjects)
    }

    /// Moves on every `invalidate(_:)`, so a lookup that finished before a sidecar changed can tell
    /// that what it read may be stale.
    public var changeCount: Int {
        state.withLock { $0.changeCount }
    }

    /// Drops the entries of the sidecars among `changedURLs`. The FSEvents watcher reports the file
    /// on a native volume and the folder that changed on a volume that reports folders only, so a
    /// sidecar whose own path or folder is listed goes. An empty list, sent when the watcher lost
    /// track, drops nothing, since a walk checks each entry against its sidecar's size and
    /// modification date before using it. Runs no file system call, so the main actor may call it.
    public func invalidate(_ changedURLs: [URL]) {
        let changed = Set(changedURLs.map { $0.standardizedFileURL.path })
        state.withLock { state in
            state.changeCount &+= 1
            guard !changed.isEmpty else { return }
            for key in Array(state.projects.keys) {
                state.projects[key]?.dropSidecars { path, entry in
                    changed.contains(path) || changed.contains(entry.folder)
                }
            }
        }
    }

    /// The index of `projectURL`, reading only the sidecars that are new or changed since a walk
    /// last used it. Nil when `isCancelled` turned true first. What was read by then is kept.
    func snapshot(
        projectURL: URL,
        maximumFiles: Int,
        isCancelled: () -> Bool,
        observer: (@Sendable (ProvenanceLineageResolver.Event) -> Void)?
    ) -> Snapshot? {
        guard let candidates = Self.candidates(in: projectURL, maximumFiles: maximumFiles, isCancelled: isCancelled) else {
            return nil
        }
        let projectKey = projectURL.standardizedFileURL.path
        let maximumProjects = self.maximumProjects
        let (cached, unread) = state.withLock { state in
            state.use(projectKey, keeping: maximumProjects)
            let entries = state.projects[projectKey]
            return (entries?.snapshot(for: candidates), entries?.unread(candidates) ?? candidates)
        }
        if let cached { return cached }
        for candidate in unread {
            if isCancelled() { return nil }
            observer?(.indexedSidecar(candidate.url))
            let record: IndexedRecord?
            switch Self.indexedRecord(at: candidate.url) {
            case .record(let read):
                record = read
            case .noRecord:
                record = nil
            case .unreadable:
                // A read error says nothing about the record, and the size and date it leaves
                // behind never change to cure it. Nothing is kept, so the snapshot lacks this
                // sidecar, is not cached, and the next walk reads the file again.
                continue
            }
            state.withLock { state in
                state.use(projectKey, keeping: maximumProjects)
                state.projects[projectKey]?.store(record, for: candidate)
            }
        }
        // Built outside the lock from a copy of the entries, so a main-actor caller of
        // `invalidate(_:)` or `changeCount` never waits while the checksum map is made.
        let (sidecars, version) = state.withLock { state in
            (state.projects[projectKey]?.sidecars ?? [:], state.projects[projectKey]?.version ?? -1)
        }
        let built = Self.makeSnapshot(of: candidates, from: sidecars)
        let present = Set(candidates.map(\.url.path))
        state.withLock { state in
            state.projects[projectKey]?.keep(
                built.snapshot, of: candidates, present: present, complete: built.complete, builtAt: version
            )
        }
        return built.snapshot
    }

    /// The producers of each checksum among `candidates`, canonical sidecars first. A record
    /// already taken by id, or a copy of a run already taken by signature, is left out. Complete
    /// when every candidate had a current entry.
    private static func makeSnapshot(
        of candidates: [Candidate],
        from sidecars: [String: SidecarEntry]
    ) -> (snapshot: Snapshot, complete: Bool) {
        var snapshot = Snapshot()
        var seenIDs = Set<UUID>()
        var seenSignatures = Set<SHA256Digest>()
        var complete = true
        for candidate in candidates {
            guard let entry = sidecars[candidate.url.path], entry.matches(candidate) else {
                complete = false
                continue
            }
            guard let record = entry.record,
                  seenIDs.insert(record.recordID).inserted,
                  seenSignatures.insert(record.signature).inserted else { continue }
            let position = snapshot.producers.count
            snapshot.producers.append(Producer(
                sidecarURL: candidate.url,
                recordID: record.recordID,
                createdAt: record.createdAt
            ))
            for checksum in record.producedChecksums {
                snapshot.byChecksum[checksum, default: []].append(position)
            }
        }
        return (snapshot, complete)
    }

    /// The full record of a sidecar, as a walk visits it: a typed mapping record through its own
    /// type, and anything else through the tolerant reader, which re-roots its paths.
    static func readRecord(at url: URL) -> ProvenanceEnvelope? {
        if MappingProvenance.isRecordFilename(url.lastPathComponent) {
            let directory = url.deletingLastPathComponent()
            return MappingProvenance.load(fromFile: url)?.recordedEnvelope(sourceDirectory: directory)
        }
        return ProvenanceRecorder.loadEnvelope(fromSidecar: url)
    }

    // MARK: - Reading a sidecar for the index

    /// What one read of a sidecar found.
    private enum SidecarRead {
        /// A record, with what the index keeps of it.
        case record(IndexedRecord)
        /// A file that read and holds no record. The index keeps that until the file changes.
        case noRecord
        /// A file that could not be read. The index keeps nothing, so the next walk tries again.
        case unreadable
    }

    /// What the index keeps of a sidecar. A current record is read through `LightRecord`, without
    /// the path re-rooting. A typed mapping record and every other layout go through the full
    /// reader as before, and only the entry is kept.
    private static func indexedRecord(at url: URL) -> SidecarRead {
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if !MappingProvenance.isRecordFilename(url.lastPathComponent),
           let light = try? ProvenanceJSON.decoder.decode(LightRecord.self, from: data) {
            return .record(IndexedRecord(light, context: PortablePath.Context.forFile(at: url)))
        }
        guard let envelope = readRecord(at: url) else { return .noRecord }
        return .record(IndexedRecord(envelope: envelope))
    }

    /// The sidecars under `projectURL` with their size and date, canonical sidecars first so a
    /// mapping record's copies never shadow the record they were copied from. Nil when cancelled.
    private static func candidates(in projectURL: URL, maximumFiles: Int, isCancelled: () -> Bool) -> [Candidate]? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        // Bundles (`.lungfishref`, `.lungfishfastq`) are document packages in the app's process, so
        // the enumerator must not skip package descendants: their sidecars are the records indexed.
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }
        var found: [Candidate] = []
        var visited = 0
        for case let url as URL in enumerator {
            if isCancelled() { return nil }
            visited += 1
            if visited > maximumFiles { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if name == ".tmp" || name == ".build" || name == "node_modules" {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isSidecarName(name) {
                found.append(Candidate(
                    url: url.standardizedFileURL,
                    size: values?.fileSize ?? -1,
                    modificationDate: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        found.sort { lhs, rhs in
            let left = rank(lhs.url), right = rank(rhs.url)
            return left == right ? lhs.url.path < rhs.url.path : left < right
        }
        return found
    }

    private static func isSidecarName(_ name: String) -> Bool {
        name == ProvenanceRecorder.provenanceFilename
            || MappingProvenance.isRecordFilename(name)
            || name.hasSuffix(".lungfish-provenance.json")
            || name.hasSuffix("-provenance.json")
    }

    private static func rank(_ url: URL) -> Int {
        let name = url.lastPathComponent
        if name == ProvenanceRecorder.provenanceFilename { return 0 }
        if name.hasSuffix(".lungfish-provenance.json") { return 1 }
        if MappingProvenance.isRecordFilename(name) { return 3 }
        return 2
    }

    // MARK: - State

    /// A sidecar as the enumeration found it.
    private struct Candidate: Equatable, Sendable {
        let url: URL
        let size: Int
        let modificationDate: Date
    }

    private struct State {
        var projects: [String: ProjectEntries] = [:]
        /// Project keys, least recently used first.
        var useOrder: [String] = []
        var changeCount = 0

        /// Marks `key` as just used, adding it, and drops the least recently used projects beyond `limit`.
        mutating func use(_ key: String, keeping limit: Int) {
            if useOrder.last != key {
                useOrder.removeAll { $0 == key }
                useOrder.append(key)
            }
            if projects[key] == nil {
                projects[key] = ProjectEntries()
            }
            while useOrder.count > limit {
                projects[useOrder.removeFirst()] = nil
            }
        }
    }

    private struct SidecarEntry {
        let size: Int
        let modificationDate: Date
        /// The folder holding the sidecar, kept so a report of a changed folder finds the sidecars
        /// in it without taking every path apart on the main actor.
        let folder: String
        /// Nil for a sidecar that read as no record, kept so it is not read again until it changes.
        let record: IndexedRecord?

        func matches(_ candidate: Candidate) -> Bool {
            size == candidate.size && modificationDate == candidate.modificationDate
        }
    }

    private struct ProjectEntries {
        /// Each sidecar read, by path, with the size and date it had when read.
        var sidecars: [String: SidecarEntry] = [:]
        /// The checksums the entries hold, so each is stored once however many records name it.
        var checksumPool = Set<String>()
        /// The last snapshot and the sidecars it was made from.
        var lastSnapshot: (candidates: [Candidate], snapshot: Snapshot)?
        /// Moves on every store and drop, so a snapshot built from an older copy is not kept.
        var version = 0

        func snapshot(for candidates: [Candidate]) -> Snapshot? {
            guard let lastSnapshot, lastSnapshot.candidates == candidates else { return nil }
            return lastSnapshot.snapshot
        }

        func unread(_ candidates: [Candidate]) -> [Candidate] {
            candidates.filter { sidecars[$0.url.path]?.matches($0) != true }
        }

        mutating func store(_ record: IndexedRecord?, for candidate: Candidate) {
            let pooled = record.map { record in
                IndexedRecord(
                    recordID: record.recordID,
                    createdAt: record.createdAt,
                    signature: record.signature,
                    producedChecksums: record.producedChecksums.map { checksumPool.insert($0).memberAfterInsert }
                )
            }
            sidecars[candidate.url.path] = SidecarEntry(
                size: candidate.size,
                modificationDate: candidate.modificationDate,
                folder: candidate.url.deletingLastPathComponent().path,
                record: pooled
            )
            version += 1
            lastSnapshot = nil
        }

        /// Drops the entries `shouldDrop` names. Only the dropped entries are collected, so a
        /// delivery that names none costs a pass over the keys and no copy of the dictionary.
        mutating func dropSidecars(where shouldDrop: (String, SidecarEntry) -> Bool) {
            let dropped = sidecars.filter { shouldDrop($0.key, $0.value) }
            guard !dropped.isEmpty else { return }
            for path in dropped.keys {
                sidecars[path] = nil
            }
            version += 1
            lastSnapshot = nil
        }

        /// Keeps `snapshot` for the next walk when nothing was stored or dropped while it was built
        /// and every candidate had an entry. The entries of sidecars no longer `present` go, so the
        /// entries never outgrow the project's sidecars. Their checksums stay in the pool until the
        /// project is dropped.
        mutating func keep(
            _ snapshot: Snapshot,
            of candidates: [Candidate],
            present: Set<String>,
            complete: Bool,
            builtAt builtVersion: Int
        ) {
            guard version == builtVersion else { return }
            if sidecars.keys.contains(where: { !present.contains($0) }) {
                sidecars = sidecars.filter { present.contains($0.key) }
                version += 1
            }
            if complete {
                lastSnapshot = (candidates, snapshot)
            }
        }
    }
}

// MARK: - The entry of one record

/// What the index keeps of one record.
private struct IndexedRecord: Sendable {
    let recordID: UUID
    let createdAt: Date
    /// A digest of the run signature, so a copy of a run under a new id still counts as that run.
    let signature: SHA256Digest
    /// The checksums the record's steps produced, each once.
    let producedChecksums: [String]
}

extension IndexedRecord {
    /// The entry of a record the full reader read.
    init(envelope: ProvenanceEnvelope) {
        let steps: [(inputs: [String], outputs: [String?])]
        if envelope.steps.isEmpty {
            steps = [(
                inputs: envelope.files.filter { $0.role != .output }.compactMap(\.checksumSHA256),
                outputs: ProvenanceLineageResolver.allOutputs(of: envelope).map(\.checksumSHA256)
            )]
        } else {
            steps = envelope.steps.map { step in
                (inputs: step.inputs.compactMap(\.checksumSHA256), outputs: step.outputs.map(\.checksumSHA256))
            }
        }
        self.init(
            recordID: envelope.id,
            createdAt: envelope.createdAt,
            signature: SHA256.hash(data: Data(ProvenanceLineageResolver.signature(of: envelope).utf8)),
            producedChecksums: Self.produced(by: steps)
        )
    }

    /// The entry of a current record read through its light fields. Each string of the signature
    /// is resolved as the full reader resolves it, so a record and its copies compare the way they
    /// do when read in full. Checksums, ids and dates hold no path and are read as written.
    init(_ light: LightRecord, context: PortablePath.Context) {
        // A sidecar repeats a few strings many times, such as one tool path in thousands of argv
        // entries, and resolving a path outside the project asks the file system. Each distinct
        // string is resolved once. The memo lives for this one sidecar and goes with its entry.
        var known: [String: String] = [:]
        func resolved(_ text: String) -> String {
            if let hit = known[text] { return hit }
            let value = PortablePath.resolve(text: text, context: context)
            let result = context.projectURL == nil
                ? value
                : PortablePath.rerootForeignProjectPaths(text: value, context: context)
            known[text] = result
            return result
        }
        let workflowName = ProvenanceName.required(
            light.workflowName.map(resolved),
            fallback: light.legacyName.map(resolved) ?? "unknown"
        )
        let steps = light.steps.map { step in
            ProvenanceLineageResolver.stepSignature(
                toolName: ProvenanceName.required(step.toolName.map(resolved)),
                argv: step.argv.map(resolved),
                outputs: step.outputs.map { $0.checksum ?? resolved($0.path) }
            )
        }
        let signature = ProvenanceLineageResolver.runSignature(workflowName: workflowName, steps: steps)
        self.init(
            recordID: light.id,
            createdAt: light.createdAt,
            signature: SHA256.hash(data: Data(signature.utf8)),
            producedChecksums: Self.produced(by: light.steps.map { step in
                (inputs: step.inputChecksums, outputs: step.outputs.map(\.checksum))
            })
        )
    }

    /// The checksums the steps produced, each once. A step that writes a byte copy of its own input
    /// (a staging symlink, an adopted BAM) did not make those bytes, so an output whose checksum is
    /// among that step's inputs is left out. A later step of the same record reading the file
    /// (samtools faidx after bgzip) does not count against it, so the rule is per step.
    static func produced(by steps: [(inputs: [String], outputs: [String?])]) -> [String] {
        var seen = Set<String>()
        var produced: [String] = []
        for step in steps {
            let inputs = Set(step.inputs)
            for case let checksum? in step.outputs where !checksum.isEmpty && !inputs.contains(checksum) {
                if seen.insert(checksum).inserted {
                    produced.append(checksum)
                }
            }
        }
        return produced
    }
}

// MARK: - The light fields of a current record

/// The fields of a current record the index needs. A record without an id, a date, a runtime
/// identity or steps fails here and goes to the full reader. The full reader gives a record without
/// an id a new one on every read, so only it can index such a record the way it always has.
private struct LightRecord: Decodable {
    let id: UUID
    let createdAt: Date
    let workflowName: String?
    let legacyName: String?
    let steps: [LightStep]

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case workflowName
        case legacyName = "name"
        case runtimeIdentity
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.runtimeIdentity) else {
            throw DecodingError.keyNotFound(
                CodingKeys.runtimeIdentity,
                .init(codingPath: container.codingPath, debugDescription: "Not a current provenance record.")
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        legacyName = try container.decodeIfPresent(String.self, forKey: .legacyName)
        steps = try container.decode([LightStep].self, forKey: .steps)
        guard !steps.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "A record without steps is read in full.")
            )
        }
    }
}

private struct LightStep: Decodable {
    let toolName: String?
    let argv: [String]
    let inputChecksums: [String]
    let outputs: [LightOutput]

    private enum CodingKeys: String, CodingKey {
        case toolName
        case argv
        case command
        case inputs
        case outputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        argv = try container.decodeIfPresent([String].self, forKey: .argv)
            ?? container.decodeIfPresent([String].self, forKey: .command)
            ?? []
        inputChecksums = try (container.decodeIfPresent([LightInput].self, forKey: .inputs) ?? []).compactMap(\.checksum)
        outputs = try container.decodeIfPresent([LightOutput].self, forKey: .outputs) ?? []
    }
}

/// An input needs only its checksum, and its path only to be present, as the full reader requires.
private struct LightInput: Decodable {
    let checksum: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case checksumSHA256
        case sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.path) else {
            throw DecodingError.keyNotFound(
                CodingKeys.path,
                .init(codingPath: container.codingPath, debugDescription: "A file names its path.")
            )
        }
        checksum = try container.decodeIfPresent(String.self, forKey: .checksumSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
    }
}

/// An output's path stands in the run signature when the output has no checksum.
private struct LightOutput: Decodable {
    let path: String
    let checksum: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case checksumSHA256
        case sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        checksum = try container.decodeIfPresent(String.self, forKey: .checksumSHA256)
            ?? container.decodeIfPresent(String.self, forKey: .sha256)
    }
}
