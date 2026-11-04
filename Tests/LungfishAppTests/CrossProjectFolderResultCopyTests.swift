// CrossProjectFolderResultCopyTests.swift - A result folder that holds its own provenance record copies to another project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, row COPY-PLAIN-FOLDER-SIDECAR (S2). The five folder-shaped result kinds a person can drag
// to another project are TaxTriage, Kraken 2, EsViritu, NVD and NAO-MGS. Each is built whole by the same fixture the
// routing safety nets use, given the root record a run writes (`.lungfish-provenance.json` listing every file with its
// digest), and copied through the real copier. A copy opens in the destination project, reads the same number, names
// its own paths in its record and leaves the source as it was. A refusal that remains names the item and what to try.

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

    // MARK: - The five kinds

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

    /// Pending the BIO ruling (lane COPYFOLDER report, "For BIO"). The import writers list the result folder itself as the
    /// first output of their step, with no digest and no size, and the copy refuses a listed output that has neither. This
    /// pins what the copy does today for such a record, so the five tests above stand for records that list files only.
    /// Once BIO rules that a folder entry may pass, flip this test to a success and add the control that a listed FILE
    /// without a digest is still refused.
    func testARecordThatListsTheFolderItselfIsRefusedPendingTheBioRuling() async throws {
        listsTheFolderItself = true
        let source = try await buildWithRecord(.nvd)
        let before = try treeDigest(of: source)

        let message = try refusal(of: source)

        expectPlainWords(message, item: source.lastPathComponent)
        XCTAssertTrue(message.contains("without a checksum"), message)
        try expectNothingLeftInTarget()
        XCTAssertEqual(try treeDigest(of: source), before)
    }

    // MARK: - Checks

    private var listsTheFolderItself = false

    private func assertCopies(_ kind: Kind, file: StaticString = #filePath, line: UInt = #line) async throws {
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
        // Its record names the copy and the files digest as they are.
        try expectRecordNamesOnly(outcome.destinationURL, file: file, line: line)
        // The source is untouched, and nothing of the stage is left.
        XCTAssertEqual(try treeDigest(of: source), before, "the source is untouched", file: file, line: line)
        XCTAssertEqual(stages(), [], file: file, line: line)
    }

    /// Every output the copy's record lists lies inside the copy, holds the digest of its file and is not the source's,
    /// and no argument or path names the source project or the stage.
    private func expectRecordNamesOnly(_ copy: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let sidecar = copy.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar), file: file, line: line)
        let outputs = record.outputs + record.steps.flatMap(\.outputs) + record.files.filter { $0.role == .output }
        XCTAssertFalse(outputs.isEmpty, "the record lists outputs", file: file, line: line)
        let inside = copy.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for output in outputs {
            let path = URL(fileURLWithPath: output.path).resolvingSymlinksInPath().standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(inside), "\(output.path) lies outside \(copy.lastPathComponent)", file: file, line: line)
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

    /// The root record a run or an import writes into its folder, with every other file listed as an output.
    private func writeRunRecord(_ kind: Kind, in folder: URL) throws {
        var outputs = try regularFiles(in: folder).filter { $0 != ProvenanceRecorder.provenanceFilename }.map { relative -> ProvenanceFileDescriptor in
            let url = folder.appendingPathComponent(relative)
            return ProvenanceFileDescriptor(
                path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
                fileSize: try ProvenanceFileHasher.fileSize(of: url), format: FileFormat.inferred(fromPath: relative), role: .output
            )
        }
        if listsTheFolderItself {
            // `writeMetagenomicsImportProvenance` (MetagenomicsImportService.swift:1230) lists the result folder itself as the
            // first output of its step, with no digest and no size, as the TaxTriage, NVD and NAO-MGS imports write it.
            outputs.insert(ProvenanceFileDescriptor(path: folder.path, format: .unknown, role: .output), at: 0)
        }
        let argv = ["lungfish-cli", kind.tool, "run", "--output", folder.path]
        let step = ProvenanceStep(
            toolName: kind.tool, toolVersion: "1.0", argv: argv, durableReplayArgv: argv, resolvedOptions: [:],
            inputs: [], outputs: outputs, exitStatus: 0, wallTimeSeconds: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), completedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), workflowName: kind.tool, workflowVersion: "1.0",
            toolName: kind.tool, toolVersion: "1.0", tool: ProvenanceToolIdentity(name: kind.tool, version: "1.0", kind: "cli"),
            argv: argv, durableReplayArgv: argv, options: ProvenanceOptions(explicit: [:], resolvedDefaults: [:]),
            files: outputs, output: nil, outputs: outputs, steps: [step], wallTimeSeconds: 3, exitStatus: 0
        )
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
