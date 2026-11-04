// CrossProjectFolderResultCopyTests.swift - A result folder that holds its own provenance record copies to another project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, row COPY-PLAIN-FOLDER-SIDECAR (S2) and ruling BIO-COPY-DIGESTLESS. The five folder-shaped
// result kinds a person can drag to another project are TaxTriage, Kraken 2, EsViritu, NVD and NAO-MGS. Each is built
// whole by the same fixture the routing safety nets use, given the root record a run or an import writes
// (`.lungfish-provenance.json` listing every file with its digest, and for an import the folder itself with none), and
// copied through the real copier. A copy opens in the destination project, reads the same number, names its own paths in
// its record and leaves the source as it was. The copier compares every file of the copy with the original. A refusal
// that remains names the item and what to try.

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class CrossProjectFolderResultCopyTests: XCTestCase {
    private enum Kind: CaseIterable {
        case taxTriage, kraken2, esViritu, nvd, naoMgs

        var tool: String {
            switch self {
            case .taxTriage: return "taxtriage"
            case .kraken2: return "kraken2"
            case .esViritu: return "esviritu"
            case .nvd: return "nvd"
            case .naoMgs: return "naomgs"
            }
        }

        var database: String {
            switch self {
            case .taxTriage: return "taxtriage.sqlite"
            case .kraken2: return "kraken2.sqlite"
            case .esViritu: return "esviritu.sqlite"
            case .nvd, .naoMgs: return "hits.sqlite"
            }
        }
    }

    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!
    private var analyses: URL!
    private let fm = FileManager.default

    /// How the record of the next fixture is written. A test sets these before it builds.
    private var listsTheFolderItself = false
    private var unlistedFiles: Set<String> = []
    private var tweakRecord: ((URL, inout ProvenanceEnvelope) -> Void)?

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CrossProjectFolderResultCopyTests-\(UUID().uuidString)", isDirectory: true)
        sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        analyses = sourceProject.appendingPathComponent("Analyses", isDirectory: true)
        try fm.createDirectory(at: analyses, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - The five kinds, with a record that lists files only and with one that lists the folder too

    func testTaxTriageResultFolderCopiesToAnotherProject() async throws { try await assertCopies(.taxTriage) }
    func testKraken2ResultFolderCopiesToAnotherProject() async throws { try await assertCopies(.kraken2) }
    func testEsVirituResultFolderCopiesToAnotherProject() async throws { try await assertCopies(.esViritu) }
    func testNvdResultFolderCopiesToAnotherProject() async throws { try await assertCopies(.nvd) }
    func testNaoMgsResultFolderCopiesToAnotherProject() async throws { try await assertCopies(.naoMgs) }

    /// A second copy of the same item gets the next free name, and its record names that name, not the source's.
    func testASecondCopyKeepsItsOwnNameInItsRecord() async throws {
        let source = try await buildWithRecord(.kraken2)
        let first = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
        let second = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
        XCTAssertEqual(second.destinationURL.lastPathComponent, first.destinationURL.lastPathComponent + "-2")
        try expectRecordNamesOnly(second.destinationURL)
        try expectRecordNamesOnly(first.destinationURL)
    }

    /// The import writers list the result folder itself as the first output of their step, with no digest and no size.
    /// Only the item's own folder passes. The copy keeps that entry free of a digest and names itself in it.
    func testARecordThatListsTheFolderItselfCopies() async throws {
        listsTheFolderItself = true
        let source = try await buildWithRecord(.nvd)
        let before = try treeDigest(of: source)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let entry = try recordOf(outcome.destinationURL).outputs.first { samePath($0.path, outcome.destinationURL.path) }
        XCTAssertNotNil(entry, "the record names the copy as an output")
        XCTAssertNil(entry?.checksumSHA256)
        try expectRecordNamesOnly(outcome.destinationURL)
        XCTAssertEqual(try treeDigest(of: source), before)
        XCTAssertEqual(stages(), [])
    }

    /// A copy of an imported result, a second copy of the same one and a copy of the copy in a third project all pass.
    func testASecondCopyOfAnImportedResultCopies() async throws {
        listsTheFolderItself = true
        let source = try await buildWithRecord(.nvd)
        let number = try fingerprint(.nvd, in: source)
        let first = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
        let second = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
        let thirdProject = root.appendingPathComponent("Third.lungfish", isDirectory: true)
        try fm.createDirectory(at: thirdProject, withIntermediateDirectories: true)

        let ofTheCopy = try CrossProjectItemCopier.copy(itemAt: first.destinationURL, intoProject: thirdProject, identity: .neutral)

        XCTAssertEqual(second.destinationURL.lastPathComponent, first.destinationURL.lastPathComponent + "-2")
        for copy in [first, second, ofTheCopy] {
            try expectRecordNamesOnly(copy.destinationURL)
            XCTAssertEqual(try fingerprint(.nvd, in: copy.destinationURL), number)
        }
    }

    /// The TaxTriage import builds its database after it writes the record, so the record does not list it. It copies,
    /// and the copy's own record of the copy lists the file with the digest the source has.
    func testAnImportWithADatabaseBuiltLaterCopies() async throws {
        listsTheFolderItself = true
        unlistedFiles = [Kind.taxTriage.database]
        let source = try await buildWithRecord(.taxTriage)
        let number = try fingerprint(.taxTriage, in: source)
        let digest = try ProvenanceFileHasher.sha256(of: source.appendingPathComponent(Kind.taxTriage.database))

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let copyRecord = try XCTUnwrap(ProjectItemCopyRecord.load(from: outcome.destinationURL))
        XCTAssertEqual(copyRecord.sourceItemFiles?.first { $0.path == Kind.taxTriage.database }?.sha256, digest)
        XCTAssertEqual(try ProvenanceFileHasher.sha256(of: outcome.destinationURL.appendingPathComponent(Kind.taxTriage.database)), digest)
        XCTAssertEqual(try fingerprint(.taxTriage, in: outcome.destinationURL), number)
    }

    // MARK: - The run level, not the steps

    /// A step keeps files as they were when it ran. `classification.kraken` was compressed and removed, and only a step
    /// lists it. The copy compares the run level, so it passes, and the copy's step entry keeps the digest at its new path.
    func testARunRecordWithARemovedStepOutputCopies() async throws {
        let removed = "classification.kraken"
        let digest = String(repeating: "ab", count: 32)
        tweakRecord = { folder, envelope in
            envelope.steps[0].outputs.append(ProvenanceFileDescriptor(
                path: folder.appendingPathComponent(removed).path, checksumSHA256: digest, fileSize: 123, format: .unknown, role: .output
            ))
        }
        let source = try await buildWithRecord(.kraken2)
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent(removed).path))

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let entry = try recordOf(outcome.destinationURL).steps[0].outputs.first { $0.path.hasSuffix("/" + removed) }
        XCTAssertEqual(entry?.checksumSHA256, digest)
        XCTAssertTrue(samePath(entry?.path ?? "", outcome.destinationURL.appendingPathComponent(removed).path), entry?.path ?? "no entry")
        try expectRecordNamesOnly(outcome.destinationURL)
    }

    /// A file that the run level lists and the folder no longer holds is refused, naming the file.
    func testARunLevelFileThatIsGoneIsStillRefused() async throws {
        let source = try await buildWithRecord(.kraken2)
        let gone = fm.fileExists(atPath: source.appendingPathComponent("classification.kreport").path)
            ? "classification.kreport" : Kind.kraken2.database
        try fm.removeItem(at: source.appendingPathComponent(gone))
        let before = try treeDigest(of: source)

        guard case .recordFileMissing(let item, let named)? = copyError(of: source) else {
            return XCTFail("a listed file that is gone must be refused as missing")
        }

        XCTAssertEqual(item, source.lastPathComponent)
        XCTAssertEqual(named, gone)
        expectPlainWords(CrossProjectItemCopier.CopyError.recordFileMissing(item: item, file: named).localizedDescription, item: item)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before)
    }

    /// A step entry whose digest is out of date does not refuse, since the step keeps the file as it was when it ran.
    func testAStepOutputThatChangedDoesNotRefuse() async throws {
        let stale = String(repeating: "cd", count: 32)
        tweakRecord = { folder, envelope in
            let database = folder.appendingPathComponent(Kind.kraken2.database).path
            envelope.steps[0].outputs = envelope.steps[0].outputs.map { output in
                guard output.path == database else { return output }
                return ProvenanceFileDescriptor(path: output.path, checksumSHA256: stale, fileSize: output.fileSize,
                                                format: output.format, role: output.role)
            }
        }
        let source = try await buildWithRecord(.kraken2)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        try expectRecordNamesOnly(outcome.destinationURL)
        XCTAssertEqual(stages(), [])
    }

    /// The control: the same change in a file that the run level lists is refused, by one flipped byte of the same size.
    func testARunLevelFileThatChangedIsStillRefused() async throws {
        let source = try await buildWithRecord(.kraken2)
        try flipLastByte(of: source.appendingPathComponent(Kind.kraken2.database))
        let before = try treeDigest(of: source)

        guard case .recordDoesNotMatch(_, let named)? = copyError(of: source) else {
            return XCTFail("a listed file that changed must be refused")
        }

        XCTAssertEqual(named, Kind.kraken2.database)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before)
    }

    // MARK: - What stays refused, and what the lists may hold

    /// A listed file without a digest is not the item's folder and is refused.
    func testADigestlessFileEntryIsStillRefused() async throws {
        listsTheFolderItself = true
        tweakRecord = { folder, envelope in
            let entry = ProvenanceFileDescriptor(path: folder.appendingPathComponent(Kind.nvd.database).path, format: .unknown, role: .output)
            envelope.outputs.append(entry)
            envelope.files.append(entry)
        }
        let source = try await buildWithRecord(.nvd)
        let before = try treeDigest(of: source)

        guard case .recordLacksChecksum(_, let named)? = copyError(of: source) else {
            return XCTFail("a digest-less file entry must be refused")
        }

        XCTAssertEqual(named, Kind.nvd.database)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before)
    }

    /// A digest-less entry for a sub-folder is not the item's folder and is refused.
    func testADigestlessSubfolderEntryIsStillRefused() async throws {
        listsTheFolderItself = true
        tweakRecord = { folder, envelope in
            let bams = folder.appendingPathComponent("bams", isDirectory: true)
            try? FileManager.default.createDirectory(at: bams, withIntermediateDirectories: true)
            try? "bam\n".write(to: bams.appendingPathComponent("S1.bam"), atomically: true, encoding: .utf8)
            let entry = ProvenanceFileDescriptor(path: bams.path, format: .unknown, role: .output)
            envelope.outputs.append(entry)
            envelope.files.append(entry)
        }
        let source = try await buildWithRecord(.nvd)

        guard case .recordLacksChecksum(_, let named)? = copyError(of: source) else {
            return XCTFail("a digest-less sub-folder entry must be refused")
        }

        XCTAssertEqual(named, "bams")
        try expectNothingLeftInTarget()
    }

    /// A `lungfish*` bundle that lists its own folder without a digest keeps the old refusal.
    func testABundleThatListsItsFolderIsStillRefused() async throws {
        let bundle = analyses.appendingPathComponent("Thing.lungfishnotes", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "data\n".write(to: bundle.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        listsTheFolderItself = true
        try writeRunRecord(.nvd, in: bundle)
        let before = try treeDigest(of: bundle)

        guard case .recordLacksChecksum(_, let named)? = copyError(of: bundle) else {
            return XCTFail("a bundle's digest-less folder entry must be refused")
        }

        XCTAssertEqual(named, "Thing.lungfishnotes")
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: bundle), before)
    }

    /// A pipe a step wrote to (`pipe:stdout:samtools-sort`) names no file in the folder and does not refuse.
    func testAPipeEntryDoesNotRefuse() async throws {
        tweakRecord = { _, envelope in
            let pipe = ProvenanceFileDescriptor(path: "pipe:stdout:samtools-sort", format: .unknown, role: .output)
            envelope.steps[0].outputs.append(pipe)
            envelope.files.append(pipe)
        }
        let source = try await buildWithRecord(.naoMgs)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        try expectRecordNamesOnly(outcome.destinationURL)
        XCTAssertEqual(stages(), [])
    }

    // MARK: - Every file of the copy against the original

    /// A file the record does not list is missing from the copy. The comparison names it.
    func testAnUnlistedFileMissingFromTheCopyIsRefused() async throws {
        let source = try await buildWithRecord(.naoMgs)
        try expectCopyDiffers(source, naming: "hits.sqlite") { try FileManager.default.removeItem(at: $0) }
    }

    /// A file the record does not list differs in the copy, first the database and then a hidden file.
    func testAnUnlistedFileChangedInTheCopyIsRefused() async throws {
        let source = try await buildWithRecord(.naoMgs)
        try "{\"zoom\": 2}\n".write(to: source.appendingPathComponent(".viewstate.json"), atomically: true, encoding: .utf8)
        try expectCopyDiffers(source, naming: "hits.sqlite") { try self.flipLastByte(of: $0) }
        try expectCopyDiffers(source, naming: ".viewstate.json") { try self.flipLastByte(of: $0) }
    }

    /// The copy writes its own root record, so the record may differ from the original's.
    func testTheRootRecordMayDifferInTheCopy() async throws {
        let source = try await buildWithRecord(.naoMgs)
        let files = try CrossProjectItemCopier.readSourceFiles(of: source, checkCancellation: {})
        let staged = root.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staged)
        try "{ \"rewritten\": true }\n".write(to: staged.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                                             atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try CrossProjectItemCopier.verifyStagedBytes(files, in: staged, item: source, checkCancellation: {}))
    }

    // MARK: - A refusal that remains

    /// A file the record lists was edited after the run. The copy is refused in the person's words, the source is
    /// left as it is and the target's `.tmp` and `Analyses` hold nothing of it.
    func testACopyOfAnEditedResultRefusesInPlainWordsAndLeavesNothingBehind() async throws {
        let source = try await buildWithRecord(.kraken2)
        let edited = source.appendingPathComponent("kraken2.sqlite")
        let handle = try FileHandle(forWritingTo: edited)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("x".utf8))
        try handle.close()
        let before = try treeDigest(of: source)

        let message = try refusal(of: source)

        expectPlainWords(message, item: source.lastPathComponent)
        XCTAssertTrue(message.contains("kraken2.sqlite"), message)
        XCTAssertTrue(message.contains("changed"), message)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before, "the refused source is untouched")
    }

    /// The record cannot be read. The copy is refused in the person's words and leaves nothing behind.
    func testACopyOfAResultWithAnUnreadableRecordRefusesInPlainWords() async throws {
        let source = try await buildWithRecord(.nvd)
        try "{ not a record".write(to: source.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                                   atomically: true, encoding: .utf8)
        let before = try treeDigest(of: source)

        let message = try refusal(of: source)

        expectPlainWords(message, item: source.lastPathComponent)
        XCTAssertTrue(message.contains("provenance record"), message)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before)
    }

    // MARK: - Checks

    private func assertCopies(_ kind: Kind, file: StaticString = #filePath, line: UInt = #line) async throws {
        for listsFolder in [false, true] {
            try resetProjects()
            listsTheFolderItself = listsFolder
            try await assertCopiesOnce(kind, file: file, line: line)
        }
    }

    private func assertCopiesOnce(_ kind: Kind, file: StaticString, line: UInt) async throws {
        let source = try await buildWithRecord(kind)
        let numberAtSource = try fingerprint(kind, in: source)
        let before = try treeDigest(of: source)

        // A person reaches the copier by dragging the item: the drop sends it to `CrossProjectItemCopier`.
        XCTAssertTrue(CrossProjectItemCopier.isCopyableProjectItem(source), "\(kind) is a copyable item", file: file, line: line)
        let partition = MainSplitViewController.partitionDroppedSources([source])
        XCTAssertEqual(partition.projectItems.map(\.lastPathComponent), [source.lastPathComponent], file: file, line: line)
        XCTAssertTrue(partition.other.isEmpty, file: file, line: line)

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        // It opens in the destination project and reads the same.
        XCTAssertEqual(outcome.kind, .analysisResult(tool: kind.tool, isBatch: false), file: file, line: line)
        XCTAssertEqual(AnalysesFolder.analysisInfo(for: outcome.destinationURL)?.tool, kind.tool, file: file, line: line)
        XCTAssertEqual(try fingerprint(kind, in: outcome.destinationURL), numberAtSource, file: file, line: line)
        XCTAssertTrue(sidebarTitles(in: targetProject).contains(source.lastPathComponent), file: file, line: line)
        // Its record names the copy and the files digest as they are, and the folder entry of an import has no digest.
        try expectRecordNamesOnly(outcome.destinationURL, file: file, line: line)
        if listsTheFolderItself {
            let entry = try recordOf(outcome.destinationURL).outputs.first { samePath($0.path, outcome.destinationURL.path) }
            XCTAssertNotNil(entry, "the record names the copy as an output", file: file, line: line)
            XCTAssertNil(entry?.checksumSHA256, file: file, line: line)
        }
        // The source is untouched, and nothing of the stage is left.
        XCTAssertEqual(try treeDigest(of: source), before, "the source is untouched", file: file, line: line)
        XCTAssertEqual(stages(), [], file: file, line: line)
    }

    private func resetProjects() throws {
        try? fm.removeItem(at: analyses)
        try? fm.removeItem(at: targetProject.appendingPathComponent("Analyses"))
        try fm.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    /// Every output the copy's record lists lies inside the copy (or is the copy), holds the digest of its file and is
    /// not the source's, and no argument or path names the source project or the stage.
    private func expectRecordNamesOnly(_ copy: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let sidecar = copy.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar), file: file, line: line)
        let outputs = record.outputs + record.steps.flatMap(\.outputs) + record.files.filter { $0.role == .output }
        XCTAssertFalse(outputs.isEmpty, "the record lists outputs", file: file, line: line)
        let base = copy.resolvingSymlinksInPath().standardizedFileURL.path
        for output in outputs {
            let path = URL(fileURLWithPath: output.path).resolvingSymlinksInPath().standardizedFileURL.path
            XCTAssertTrue(path == base || path.hasPrefix(base + "/"), "\(output.path) lies outside \(copy.lastPathComponent)", file: file, line: line)
            XCTAssertFalse(output.path.contains("Source.lungfish"), output.path, file: file, line: line)
            if let digest = output.checksumSHA256, FileManager.default.fileExists(atPath: path) {
                XCTAssertEqual(digest, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: path)), output.path, file: file, line: line)
            }
        }
        XCTAssertFalse(record.argv.contains { $0.contains("Source.lungfish") }, "\(record.argv)", file: file, line: line)
        let text = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        XCTAssertFalse(text.contains("project-copy-"), "the record names the stage", file: file, line: line)
    }

    private func refusal(of source: URL) throws -> String {
        var message = ""
        XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)) {
            message = $0.localizedDescription
        }
        return message
    }

    /// The copy's error as the copier throws it. A copy that succeeds, or an error of another type, fails the test.
    private func copyError(of source: URL, file: StaticString = #filePath, line: UInt = #line) -> CrossProjectItemCopier.CopyError? {
        do {
            _ = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)
            XCTFail("the copy was made", file: file, line: line)
            return nil
        } catch let problem as CrossProjectItemCopier.CopyError {
            return problem
        } catch {
            XCTFail("a raw error reached the person: \(error)", file: file, line: line)
            return nil
        }
    }

    /// Verifies a staged copy that `damage` changed in the file `named`, and expects the comparison to name that file.
    private func expectCopyDiffers(
        _ source: URL, naming named: String, damage: (URL) throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let files = try CrossProjectItemCopier.readSourceFiles(of: source, checkCancellation: {})
        let staged = root.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staged)
        try damage(staged.appendingPathComponent(named))
        XCTAssertThrowsError(try CrossProjectItemCopier.verifyStagedBytes(files, in: staged, item: source, checkCancellation: {}),
                             file: file, line: line) { error in
            guard case .copyDiffers(let item, let differing)? = error as? CrossProjectItemCopier.CopyError else {
                return XCTFail("not refused as a copy that differs: \(error)", file: file, line: line)
            }
            XCTAssertEqual(item, source.lastPathComponent, file: file, line: line)
            XCTAssertEqual(differing, named, file: file, line: line)
            self.expectPlainWords(error.localizedDescription, item: item, file: file, line: line)
        }
    }

    private func flipLastByte(of url: URL) throws {
        var data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        data[data.count - 1] ^= 0xFF
        try data.write(to: url)
    }

    private func recordOf(_ copy: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: copy.appendingPathComponent(ProvenanceRecorder.provenanceFilename)))
    }

    private func samePath(_ first: String, _ second: String) -> Bool {
        URL(fileURLWithPath: first).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: second).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The words name the item, say what happened and what to try, and keep the hidden stage, the word sidecar and
    /// the old internal sentences out.
    private func expectPlainWords(_ message: String, item: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(message.contains(item), "names the item: \(message)", file: file, line: line)
        XCTAssertTrue(message.contains("was not copied"), message, file: file, line: line)
        XCTAssertTrue(message.contains("copy it again"), "says what to try: \(message)", file: file, line: line)
        for old in ["sidecar", ".tmp", "project-copy-", "Source provenance", "final bundle"] {
            XCTAssertFalse(message.contains(old), "\(old) in: \(message)", file: file, line: line)
        }
    }

    private func expectNothingLeftInTarget(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(stages(), [], "a failed copy leaves its stage", file: file, line: line)
        let landed = (try? fm.contentsOfDirectory(atPath: targetProject.appendingPathComponent("Analyses").path)) ?? []
        XCTAssertEqual(landed, [], "a failed copy leaves part of the item", file: file, line: line)
    }

    // MARK: - Fixtures

    private func buildWithRecord(_ kind: Kind) async throws -> URL {
        let folder = try await build(kind)
        try writeRunRecord(kind, in: folder)
        return folder
    }

    private func build(_ kind: Kind) async throws -> URL {
        switch kind {
        case .taxTriage:
            let folder = try RoutingSafetyNetFixtures.taxTriageResult(named: "taxtriage-2026-09-24T09-00-00", in: analyses, samples: ["S1", "S2"])
            try AnalysesFolder.writeAnalysisMetadata(.init(tool: kind.tool, isBatch: false), to: folder)
            return folder
        case .kraken2:
            let folder = try RoutingSafetyNetFixtures.kraken2Result(named: "kraken2-2026-09-24T10-00-00", in: analyses, samples: ["S1", "S2"])
            try AnalysesFolder.writeAnalysisMetadata(.init(tool: kind.tool, isBatch: false), to: folder)
            return folder
        case .esViritu:
            let folder = try RoutingSafetyNetFixtures.esVirituResult(named: "esviritu-2026-09-24T11-00-00", in: analyses, samples: ["S1", "S2"])
            try AnalysesFolder.writeAnalysisMetadata(.init(tool: kind.tool, isBatch: false), to: folder)
            return folder
        case .nvd:
            return try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-SampleB", in: analyses).bundle
        case .naoMgs:
            return try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-SampleA", in: analyses).bundle
        }
    }

    /// The root record a run or an import writes into its folder, with every other file listed as an output except the
    /// files `unlistedFiles` names. `tweakRecord` may change the record before it is written.
    private func writeRunRecord(_ kind: Kind, in folder: URL) throws {
        var outputs = try regularFiles(in: folder)
            .filter { $0 != ProvenanceRecorder.provenanceFilename && !unlistedFiles.contains($0) }
            .map { relative -> ProvenanceFileDescriptor in
                let url = folder.appendingPathComponent(relative)
                return ProvenanceFileDescriptor(
                    path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
                    fileSize: try ProvenanceFileHasher.fileSize(of: url), format: FileFormat.inferred(fromPath: relative), role: .output
                )
            }
        if listsTheFolderItself {
            // `writeMetagenomicsImportProvenance` (MetagenomicsImportService.swift:1230) lists the result folder itself as the
            // first output of its step, with no digest and no size, as the five imports write it.
            outputs.insert(ProvenanceFileDescriptor(path: folder.path, format: .unknown, role: .output), at: 0)
        }
        let argv = ["lungfish-cli", kind.tool, "run", "--output", folder.path]
        let step = ProvenanceStep(
            toolName: kind.tool, toolVersion: "1.0", argv: argv, durableReplayArgv: argv, resolvedOptions: [:],
            inputs: [], outputs: outputs, exitStatus: 0, wallTimeSeconds: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        var envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), workflowName: kind.tool, workflowVersion: "1.0",
            toolName: kind.tool, toolVersion: "1.0", tool: ProvenanceToolIdentity(name: kind.tool, version: "1.0", kind: "cli"),
            argv: argv, durableReplayArgv: argv, options: ProvenanceOptions(explicit: [:], resolvedDefaults: [:]),
            files: outputs, output: nil, outputs: outputs, steps: [step], wallTimeSeconds: 3, exitStatus: 0
        )
        tweakRecord?(folder, &envelope)
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: folder)
    }

    /// A number the result's own reader gives: the count of rows or hits per sample that its database holds.
    private func fingerprint(_ kind: Kind, in folder: URL) throws -> String {
        let database = folder.appendingPathComponent(kind.database)
        switch kind {
        case .taxTriage:
            return try TaxTriageDatabase(at: database).fetchSamples().map { "\($0.sample)=\($0.organismCount)" }.sorted().joined(separator: ",")
        case .kraken2:
            return try Kraken2Database(at: database).fetchSamples().map { "\($0.sample)=\($0.taxonCount)" }.sorted().joined(separator: ",")
        case .esViritu:
            return try EsVirituDatabase(at: database).fetchSamples().map { "\($0.sample)=\($0.detectionCount)" }.sorted().joined(separator: ",")
        case .nvd:
            return "hits=\(try NvdDatabase(at: database).totalHitCount(samples: nil))"
        case .naoMgs:
            return "taxa=\(try NaoMgsDatabase(at: database).fetchTaxonSummaryRows(samples: nil).count)"
        }
    }

    private func regularFiles(in folder: URL) throws -> [String] {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try enumerator.compactMap { $0 as? URL }.compactMap { url -> String? in
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }.sorted()
    }

    private func treeDigest(of folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for relative in try regularFiles(in: folder) {
            digests[relative] = try ProvenanceFileHasher.sha256(of: folder.appendingPathComponent(relative))
        }
        return digests
    }

    private func stages() -> [String] {
        let temp = ProjectTempDirectory.tempRoot(for: targetProject)
        return ((try? fm.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    private func sidebarTitles(in project: URL) -> [String] {
        func collect(_ nodes: [SidebarScanNode]) -> [String] {
            nodes.flatMap { [$0.url?.lastPathComponent ?? $0.title] + collect($0.children) }
        }
        return collect(SidebarProjectScanner.scanRootNodes(from: project))
    }
}
