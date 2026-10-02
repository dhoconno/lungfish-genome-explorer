// FASTQBundleRootSequenceURLsTests.swift - The root files a derived manifest's rootFASTQFilename names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A derived bundle records one root file. When the root bundle holds several
// files (an ONT import or a merged bundle, listed in source-files.json), the
// derivative's reads come from every one of them, in manifest order, so the
// resolution expands the recorded file to the whole list. The dashboard used
// to record the primary file's bare name (`run_0.fastq`) for a file that
// lives at `chunks/run_0.fastq`, so a bare name that matches a member by name
// expands too (R3, lane 1x).

import Foundation
import XCTest
@testable import LungfishIO

final class FASTQBundleRootSequenceURLsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-sequence-urls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    private func makeSingleFileBundle() throws -> (bundle: URL, file: URL) {
        let bundle = root.appendingPathComponent("single.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("single.fastq")
        try fastq(["s1", "s2"]).write(to: file, atomically: true, encoding: .utf8)
        return (bundle, file)
    }

    /// The ONT import shape: chunk files under `chunks/`, listed in source-files.json.
    private func makeMultiFileBundle(named name: String = "multi") throws -> (bundle: URL, chunks: [URL]) {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        let chunksDirectory = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let chunks = [
            chunksDirectory.appendingPathComponent("run_0.fastq"),
            chunksDirectory.appendingPathComponent("run_1.fastq"),
        ]
        try fastq(["m1", "m2"]).write(to: chunks[0], atomically: true, encoding: .utf8)
        try fastq(["m3", "m4", "m5"]).write(to: chunks[1], atomically: true, encoding: .utf8)
        try fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        return (bundle, chunks)
    }

    private func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.standardizedFileURL.path }
    }

    func testASingleFileRootIsItsOneRecordedFile() throws {
        let single = try makeSingleFileBundle()
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "single.fastq", in: single.bundle)
        XCTAssertEqual(paths(resolved), paths([single.file]))
    }

    func testAMultiFileRootExpandsItsPrimaryMemberToEveryMemberInManifestOrder() throws {
        let multi = try makeMultiFileBundle()
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "chunks/run_0.fastq", in: multi.bundle)
        XCTAssertEqual(paths(resolved), paths(multi.chunks))
    }

    func testAnyMemberOfAMultiFileRootExpandsToEveryMember() throws {
        let multi = try makeMultiFileBundle()
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "chunks/run_1.fastq", in: multi.bundle)
        XCTAssertEqual(paths(resolved), paths(multi.chunks))
    }

    /// The dashboard recorded `run_0.fastq` for `chunks/run_0.fastq` before lane
    /// 1x, so every derivative of an ONT or merged root on disk names a file
    /// that does not exist. The bare name matches the member by name.
    func testABareNameRecordedForAChunkExpandsToEveryMember() throws {
        let multi = try makeMultiFileBundle()
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "run_0.fastq", in: multi.bundle)
        XCTAssertEqual(paths(resolved), paths(multi.chunks))
    }

    func testABareNameThatMatchesNoMemberStaysTheOneMissingFile() throws {
        let multi = try makeMultiFileBundle()
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "elsewhere.fastq", in: multi.bundle)
        XCTAssertEqual(paths(resolved), paths([multi.bundle.appendingPathComponent("elsewhere.fastq")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved[0].path), "the caller sees the missing file and fails loudly")
    }

    /// A file that exists at the recorded path is that file, even in a
    /// multi-file bundle, so a recorded name never silently becomes a
    /// different set of reads.
    func testARecordedFileThatExistsOutsideTheMembersIsThatOneFile() throws {
        let multi = try makeMultiFileBundle()
        let extra = multi.bundle.appendingPathComponent("extra.fastq")
        try fastq(["e1"]).write(to: extra, atomically: true, encoding: .utf8)
        let resolved = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "extra.fastq", in: multi.bundle)
        XCTAssertEqual(paths(resolved), paths([extra]))
    }

    /// A root missing a member is never read as a shorter bundle, not even
    /// when the recorded file is one of the members that still exist.
    func testAMultiFileRootWithAMissingMemberFailsLoudly() throws {
        let multi = try makeMultiFileBundle()
        try FileManager.default.removeItem(at: multi.chunks[1])
        XCTAssertThrowsError(
            try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "chunks/run_0.fastq", in: multi.bundle)
        ) { error in
            XCTAssertEqual(
                error as? FASTQBundlePathError,
                .missingMember(bundle: "multi.lungfishfastq", path: "chunks/run_1.fastq")
            )
        }
    }

    func testAnUnsafeRecordedPathIsRefused() throws {
        let multi = try makeMultiFileBundle()
        XCTAssertThrowsError(try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "../run_0.fastq", in: multi.bundle)) { error in
            XCTAssertTrue(error is FASTQBundlePathError, "\(error)")
        }
    }

    func testBundleRelativePathNamesAMemberTheWayRootFASTQFilenameRecordsIt() throws {
        let multi = try makeMultiFileBundle()
        XCTAssertEqual(FASTQBundle.bundleRelativePath(of: multi.chunks[0], in: multi.bundle), "chunks/run_0.fastq")
        let single = try makeSingleFileBundle()
        XCTAssertEqual(FASTQBundle.bundleRelativePath(of: single.file, in: single.bundle), "single.fastq")
        XCTAssertNil(FASTQBundle.bundleRelativePath(of: single.file, in: multi.bundle), "a file outside the bundle has no member path")
        XCTAssertNil(FASTQBundle.bundleRelativePath(of: multi.bundle, in: multi.bundle), "the bundle itself is not a member")
    }

    /// The member path round-trips through the validated member resolution,
    /// so the manifest a derivative writes with it resolves again.
    func testBundleRelativePathIsAValidMemberPath() throws {
        let multi = try makeMultiFileBundle()
        let relative = try XCTUnwrap(FASTQBundle.bundleRelativePath(of: multi.chunks[1], in: multi.bundle))
        let validated = try FASTQBundle.validatedBundleMemberURL(for: relative, in: multi.bundle, field: "rootFASTQFilename")
        XCTAssertEqual(validated.standardizedFileURL.path, multi.chunks[1].standardizedFileURL.path)
    }

    /// The manifest's integrity and staleness reports follow the same
    /// resolution as the materializer, so a derivative over a multi-file
    /// root that recorded the bare chunk name is intact, a change to any
    /// member makes it stale, and a root missing a member is not intact.
    func testIntegrityAndStalenessCheckEveryRootFile() throws {
        let multi = try makeMultiFileBundle()
        let derived = root.appendingPathComponent("subset.lungfishfastq")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try "m1\n".write(to: derived.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "m")
        let manifest = FASTQDerivedBundleManifest(
            name: "subset",
            parentBundleRelativePath: "multi.lungfishfastq",
            rootBundleRelativePath: "multi.lungfishfastq",
            rootFASTQFilename: "run_0.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .placeholder(readCount: 1, baseCount: 10),
            pairingMode: .singleEnd
        )
        XCTAssertTrue(manifest.validateIntegrity(bundleURL: derived).rootPayloadFileExists, "the bare name resolves to the members, which exist")
        XCTAssertEqual(manifest.isStale(bundleURL: derived), false, "no member changed after the derivative was made")

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: multi.chunks[1].path)
        XCTAssertEqual(manifest.isStale(bundleURL: derived), true, "a change to a member other than the recorded one")

        try FileManager.default.removeItem(at: multi.chunks[1])
        XCTAssertFalse(manifest.validateIntegrity(bundleURL: derived).rootPayloadFileExists, "a root missing a member is not intact")
        XCTAssertNil(manifest.isStale(bundleURL: derived), "staleness is unknown for a root missing a member")
    }
}
