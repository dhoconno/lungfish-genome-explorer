// CrossProjectFolderResultCopyTests+MarkedBAM.swift - A result whose BAM its own run marked in place copies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, ruling BIO-COPY-CHANGED-FILES (row COPY-MARKED-BAM-REFUSED). The index that a TaxTriage run
// builds in process marks the duplicates of each BAM in place, so the BAM the run leaves is not the BAM that the run level
// of its record names. A later step of the same record names the new bytes and a removal step names the old ones, so the
// record is true about the file, and the copy compares the file with the step that last wrote it. A file that no step
// accounts for, or that changed after its step, stays refused, and the words of a refusal blame no person for what
// Lungfish did. The BAM is a plain text file here, since the comparison reads bytes and no tool runs.

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

extension CrossProjectFolderResultCopyTests {
    /// The bytes of `minimap2/S.bam` at the moments the record tells of, and bytes it tells nothing of.
    private enum BAMBytes {
        static let path = "minimap2/S.bam"
        /// What the mapper wrote, which the run level of the record names.
        static let mapper = Data("bytes the mapper wrote\n".utf8)
        /// What the run left after it marked the duplicates, which a later step names and the file holds.
        static let marked = Data("bytes after the run marked the duplicates\n".utf8)
        /// What an outside program left, which no step names.
        static let outside = Data("bytes an outside program left\n".utf8)
        /// The bytes of some other file, which another removal step names.
        static let other = Data("bytes some other step removed\n".utf8)

        static func step(
            _ tool: String, after seconds: TimeInterval, options: [String: ParameterValue] = [:],
            inputs: [ProvenanceFileDescriptor] = [], outputs: [ProvenanceFileDescriptor] = []
        ) -> ProvenanceStep {
            let started = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
            return ProvenanceStep(
                toolName: tool, toolVersion: "1.0", argv: [tool], durableReplayArgv: [tool], resolvedOptions: options,
                inputs: inputs, outputs: outputs, exitStatus: 0, wallTimeSeconds: 1,
                startedAt: started, completedAt: started.addingTimeInterval(1)
            )
        }
    }

    // MARK: - A BAM the record accounts for

    /// The run level names the mapper's bytes, a later step names the marked bytes and a removal step names the mapper's
    /// as gone. The file holds the marked bytes, so it copies, and the copy's record names the marked bytes at its own path.
    func testARunWhoseRecordNamesItsMarkedBAMCopies() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.marked)
        let before = try treeDigest(of: source)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        try expectRunLevelNames(BAMBytes.marked, in: outcome.destinationURL)
        XCTAssertEqual(try treeDigest(of: source), before, "the source is untouched")
        XCTAssertEqual(stages(), [])
    }

    /// The copy's record names the bytes the file holds, so a copy of the copy passes the same check.
    func testASecondCopyOfARunWithAMarkedBAMCopies() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.marked)
        let first = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
        let thirdProject = root.appendingPathComponent("Third.lungfish", isDirectory: true)
        try fm.createDirectory(at: thirdProject, withIntermediateDirectories: true)

        let second = try CrossProjectItemCopier.copy(itemAt: first.destinationURL, intoProject: thirdProject, identity: .neutral)

        for copy in [first, second] {
            try expectRunLevelNames(BAMBytes.marked, in: copy.destinationURL)
        }
    }

    /// A run of this version writes its run level without the bytes a removal step names, so the BAM is not at the run
    /// level. It copies, and the copy's own record lists the BAM with the bytes it holds.
    func testARunOfThisVersionWithAMarkedBAMCopies() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.marked, droppingRemoved: true)
        let sourceRecord = try recordOf(source)
        XCTAssertFalse((sourceRecord.outputs + sourceRecord.files).contains { $0.path.hasSuffix("/" + BAMBytes.path) },
                       "a run of this version leaves the bytes a removal step names out of its run level")
        let before = try treeDigest(of: source)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let copyRecord = try XCTUnwrap(ProjectItemCopyRecord.load(from: outcome.destinationURL))
        let marked = try bamEntry(BAMBytes.marked, in: source)
        XCTAssertEqual(copyRecord.sourceItemFiles?.first { $0.path == BAMBytes.path }?.sha256, marked.checksumSHA256)
        XCTAssertEqual(try treeDigest(of: source), before)
        XCTAssertEqual(stages(), [])
    }

    // MARK: - A BAM the record does not account for stays refused

    /// The file changed after its step, so the step that last wrote it does not describe it.
    func testAMarkedBAMChangedAfterItsStepIsRefused() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.outside)
        try expectRefusedAsDifferent(source)
    }

    /// No removal step accounts for the change, so the run level keeps the digest it names and the file is refused.
    func testARunLevelDigestNoStepAccountsForIsStillRefused() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.marked, removed: nil)
        try expectRefusedAsDifferent(source)
    }

    /// A removal step that names other bytes at the same path does not excuse the file.
    func testARemovalStepOfOtherBytesDoesNotExcuseAFile() async throws {
        let source = try await markedBAMResult(holding: BAMBytes.marked, removed: BAMBytes.other)
        try expectRefusedAsDifferent(source)
    }

    // MARK: - Words

    /// A refusal says who may have changed the file and blames no person for what Lungfish did.
    func testTheRefusalWordsDoNotBlameThePerson() {
        let item = "taxtriage-cornea"
        let file = BAMBytes.path
        let changed = CrossProjectItemCopier.CopyError.recordDoesNotMatch(item: item, file: file).localizedDescription
        let gone = CrossProjectItemCopier.CopyError.recordFileMissing(item: item, file: file).localizedDescription

        for words in [changed, gone] {
            XCTAssertTrue(words.hasPrefix("\(item) was not copied."), words)
            XCTAssertTrue(words.contains(file), words)
            XCTAssertTrue(words.contains("an earlier version of Lungfish") || words.contains("Lungfish may have removed it"), words)
            XCTAssertTrue(words.contains("This copy changed nothing in the original"), words)
            XCTAssertFalse(words.contains("has changed since"), words)
        }
        XCTAssertTrue(changed.contains("A person or another program may have changed it"), changed)
        XCTAssertTrue(gone.contains("A person or another program may have removed it"), gone)
    }

    // MARK: - Fixture

    /// A TaxTriage result whose BAM was marked inside its run, as the record of `taxtriage-cornea` tells it. The run level and
    /// the first step name the mapper's bytes, a later step (`samtools markdup`) names the marked bytes, and unless `removed`
    /// is nil a removal step names `removed` as gone at the BAM's path. The file holds `held`. A run of this version
    /// (`droppingRemoved`) writes its run level through `droppingRemovedRunLevelFiles()`.
    private func markedBAMResult(holding held: Data, removed: Data? = BAMBytes.mapper, droppingRemoved: Bool = false) async throws -> URL {
        let folder = try await build(.taxTriage)
        let bam = folder.appendingPathComponent(BAMBytes.path)
        try fm.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try held.write(to: bam)
        let mapperEntry = try bamEntry(BAMBytes.mapper, in: folder)
        let markedEntry = try bamEntry(BAMBytes.marked, in: folder)
        let removedEntry = try removed.map { try bamEntry($0, in: folder) }
        tweakRecord = { _, envelope in
            func named(_ list: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
                list.map { $0.path == mapperEntry.path ? mapperEntry : $0 }
            }
            envelope.outputs = named(envelope.outputs)
            envelope.files = named(envelope.files)
            envelope.steps[0].outputs = named(envelope.steps[0].outputs)
            envelope.steps.append(BAMBytes.step("samtools markdup", after: 10, outputs: [markedEntry]))
            if let removedEntry {
                envelope.steps.append(BAMBytes.step(
                    "Lungfish Markdup Replacement", after: 20, options: RecordedRemovalStep.resolvedOptions, inputs: [removedEntry]
                ))
            }
            if droppingRemoved { envelope = envelope.droppingRemovedRunLevelFiles() }
        }
        try writeRunRecord(.taxTriage, in: folder)
        return folder
    }

    /// The record entry of `data` at the BAM's path in `folder`, hashed as the copier hashes.
    private func bamEntry(_ data: Data, in folder: URL) throws -> ProvenanceFileDescriptor {
        let scratch = root.appendingPathComponent("digest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        try data.write(to: scratch)
        return ProvenanceFileDescriptor(
            path: folder.appendingPathComponent(BAMBytes.path).path, checksumSHA256: try ProvenanceFileHasher.sha256(of: scratch),
            fileSize: try ProvenanceFileHasher.fileSize(of: scratch), format: .unknown, role: .output
        )
    }

    /// Every run-level entry the copy's record holds for the BAM names `data` at the copy's own path, and the copy holds them.
    private func expectRunLevelNames(_ data: Data, in copy: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try recordOf(copy)
        let expected = try bamEntry(data, in: copy)
        let entries = ([record.output].compactMap { $0 } + record.outputs + record.files.filter { $0.role == .output })
            .filter { samePath($0.path, expected.path) }
        XCTAssertFalse(entries.isEmpty, "the run level of \(copy.lastPathComponent) names the BAM", file: file, line: line)
        for entry in entries {
            XCTAssertEqual(entry.checksumSHA256, expected.checksumSHA256, entry.path, file: file, line: line)
            XCTAssertEqual(entry.fileSize, expected.fileSize, entry.path, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent(BAMBytes.path)), data, file: file, line: line)
    }

    /// The copy is refused as a file that does not match the record, naming the BAM, and nothing is left behind.
    private func expectRefusedAsDifferent(_ source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try treeDigest(of: source)
        guard case .recordDoesNotMatch(let item, let named)? = copyError(of: source, file: file, line: line) else {
            return XCTFail("a BAM that no step accounts for must be refused as not matching its record", file: file, line: line)
        }
        XCTAssertEqual(item, source.lastPathComponent, file: file, line: line)
        XCTAssertEqual(named, BAMBytes.path, file: file, line: line)
        try expectNothingLeftInTarget(file: file, line: line)
        XCTAssertEqual(try treeDigest(of: source), before, "the refused source is untouched", file: file, line: line)
    }
}
