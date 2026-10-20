// CrossProjectCopyLegacyRecordReplayTests.swift - An old cross-project copy record replays through fastq import-ont
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18, BIO ruling on `caller` (answer 3) as the ruling on F3 (section 1) re-rules it, frozen by
// Phase 2.13 lane 13.03 (DEL-REST, review N1 item 3 of lane 12.18). A released Lungfish copied a read bundle
// between projects in its own process and recorded the copy as
// `lungfish fastq import-ont <source> --output <destination>` with `caller` `app-cross-project-copy`. Such a
// record keeps replaying through the built CLI, since `fastq import-ont` still takes an existing bundle.
//
// The record is frozen as text in `CrossProjectCopyLegacyRecordFixture`, written once by that copier, so an edit
// to the copier, the workflow or the hasher cannot change what this test calls old. The source of the replay is
// built from the fixture's bytes. The envelope is read with the placeholder-only `PortablePath.resolveJSON`,
// never through `ProvenanceEnvelopeReader`, whose re-root would turn the source item into the copy. The source
// comes from `project-copy.json`'s `sourceItemPath`, the one record that keeps it in a form a replay can use,
// moved from the example user's project onto the project this test builds. A released record is schema 1 and
// has no `sourceItemFiles`, so the digests compared are the ones the copy's envelope names.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class CrossProjectCopyLegacyRecordReplayTests: XCTestCase {
    private typealias Fixture = CrossProjectCopyLegacyRecordFixture

    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cross-project-copy-legacy-replay")
        sourceProject = root.appendingPathComponent("S.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("T.lungfish", isDirectory: true)
        for project in [sourceProject!, targetProject!] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAppCrossProjectCopyRecordReplaysThroughFastqImportONT() throws {
        let copy = try writeFrozenCopy("Imports/R.lungfishfastq")
        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: copy))
        XCTAssertEqual(record.schemaVersion, 1, "a released record is schema 1")
        XCTAssertNil(record.sourceItemFiles, "a released record has no sourceItemFiles")
        let sidecar = copy.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let resolved = try PortablePath.resolveJSON(Data(contentsOf: sidecar), context: .forFile(at: sidecar))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        let options = try JSONDecoder().decode(
            ProvenanceOptions.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(json["options"]))
        )
        XCTAssertEqual(options.resolvedDefaults["caller"], .string("app-cross-project-copy"))

        var replay = try XCTUnwrap(json["durableReplayArgv"] as? [String])
        XCTAssertEqual(Array(replay.dropFirst().prefix(2)), ["fastq", "import-ont"], "\(replay)")
        XCTAssertGreaterThan(replay.count, 3, "\(replay)")
        replay[3] = try writeReplaySource(for: record)
        let outputIndex = try XCTUnwrap(replay.firstIndex(of: "--output"), "\(replay)") + 1
        let replayFolder = root.appendingPathComponent("replay", isDirectory: true)
        try FileManager.default.createDirectory(at: replayFolder, withIntermediateDirectories: true)
        let replayed = replayFolder.appendingPathComponent("R.lungfishfastq", isDirectory: true)
        replay[outputIndex] = replayed.path

        let run = try runCLI(Array(replay.dropFirst()))
        XCTAssertEqual(run.status, 0, "\(replay). \(run.stderr)")

        let outputs = try XCTUnwrap(json["outputs"] as? [[String: Any]])
        var recorded: [String: String] = [:]
        for output in outputs {
            guard let checksum = output["checksumSHA256"] as? String, let path = output["path"] as? String else { continue }
            recorded[try XCTUnwrap(Self.relative(path, in: copy), path)] = checksum
        }
        var compared = 0
        for file in Self.regularFiles(in: replayed) {
            let name = try XCTUnwrap(Self.relative(file.path, in: replayed), file.path)
            if name.hasSuffix(ProvenanceWriter.provenanceFilename) || name == ProjectItemCopyRecord.filename { continue }
            let digest = try ProvenanceFileHasher.sha256(of: file)
            XCTAssertEqual(digest, recorded[name], "\(name) regenerates the digest the old record names")
            compared += 1
        }
        XCTAssertEqual(compared, recorded.count, "every output the old record names is compared")
        XCTAssertGreaterThan(compared, 0)
    }

    // MARK: - Helpers

    /// The frozen copy at `relative` inside the target project, with its envelope and its schema 1 record.
    private func writeFrozenCopy(_ relative: String) throws -> URL {
        let copy = targetProject.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data(Fixture.copyProvenance.utf8).write(to: copy.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        try Data(Fixture.copyRecord.utf8).write(to: copy.appendingPathComponent(ProjectItemCopyRecord.filename))
        return copy
    }

    /// The read bundle the old record names as its source, built from the fixture's bytes at the same place
    /// inside the source project of this test. Returns its path. The bundle has readable provenance and no link
    /// into its project, so the replay goes through `FASTQBundleCopyImportWorkflow`.
    private func writeReplaySource(for record: ProjectItemCopyRecord) throws -> String {
        let project = try XCTUnwrap(record.sourceProjectPath)
        let relative = try XCTUnwrap(
            ProjectItemLinkRewriter.relative(path: record.sourceItemPath, toAny: [project]), record.sourceItemPath
        )
        let bundle = sourceProject.appendingPathComponent(relative, isDirectory: true)
        let envelope = Data(Fixture.sourceProvenance.utf8)
        let files: [(String, Data)] = [
            ("reads.fastq", Data(Fixture.sourceReads.utf8)),
            (ProvenanceWriter.provenanceFilename, envelope),
            ("provenance/bundle.lungfish-provenance.json", envelope),
            ("provenance/reads.fastq.lungfish-provenance.json", envelope),
        ]
        for (name, data) in files {
            let file = bundle.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return bundle.path
    }

    /// `path` as a path inside `folder`, nil when it is outside, with symlinks such as `/var` resolved on both.
    private static func relative(_ path: String, in folder: URL) -> String? {
        let file = URL(fileURLWithPath: path)
        let prefixes = [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path]
        return ProjectItemLinkRewriter.relative(path: file.standardizedFileURL.path, toAny: prefixes)
            ?? ProjectItemLinkRewriter.relative(path: file.resolvingSymlinksInPath().path, toAny: prefixes)
    }

    private static func regularFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
    }

    /// Runs the built `lungfish-cli` to the end from the test's folder.
    private func runCLI(_ arguments: [String]) throws -> ProcessResult {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: Self.self),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        return try ProcessRunner.run(
            binary, arguments, environment: CLISIGTERMHarness.childEnvironment(), cwd: root, timeout: 60
        )
    }
}
