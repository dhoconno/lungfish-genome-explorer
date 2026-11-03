// SavedBlastSearchFixture.swift - A project with saved `blast submit` records, for the tests of a result's return
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A temporary project whose `blast-verifications` folder holds `blast submit` records, as the NAO-MGS, EsViritu,
/// TaxTriage and NVD rows save them (Phase 3.1 lane REOPEN). Every record is made here, so no test holds real data.
public struct SavedBlastSearchProject {
    public let root: URL
    public var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    public init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-blast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// `<project>/Analyses/<name>`, created.
    public func result(_ name: String) throws -> URL {
        let url = project.appendingPathComponent("Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves a record of the search `rid` from the result `Analyses/<sourceResult>`, in the `@/` form the leaf writes.
    /// `age` is how many seconds before a fixed date it completed, so a smaller age is newer.
    @discardableResult
    public func saveRecord(
        rid: String,
        sourceResult: String,
        sample: String?,
        taxId: Int?,
        contig: String?,
        age: TimeInterval = 0
    ) throws -> URL {
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000 - age)
        let result = BlastVerificationResult(
            taxonName: "Example virus", taxId: taxId ?? 0, totalReads: 0, verifiedCount: 0, ambiguousCount: 0,
            unverifiedCount: 0, errorCount: 0, readResults: [], submittedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt, rid: rid, blastProgram: "blastn", database: "core_nt"
        )
        let record = BlastSubmissionRecord(
            savedAt: completedAt,
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: "0", sequenceCount: 0),
            lineage: .init(sourceResult: "@/Analyses/\(sourceResult)", sample: sample, taxId: taxId, contig: contig),
            search: .init(BlastVerificationRequest(
                taxonName: "Example virus", taxId: taxId ?? 0, sequences: [(id: "read", sequence: "ACGT")], database: "core_nt"
            )),
            result: result
        )
        let folder = searchFolder(named: "search-\(rid)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        try BlastSubmissionRecord.encoder.encode(record).write(to: url)
        return url
    }

    /// A search's folder with no readable record, which a timed-out run leaves.
    public func saveFolderWithNoReadableRecord(named name: String) throws {
        let folder = searchFolder(named: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not a record".utf8).write(to: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
    }

    private func searchFolder(named name: String) -> URL {
        project.appendingPathComponent("blast-verifications/\(name)", isDirectory: true)
    }
}
