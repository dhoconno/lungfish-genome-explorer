// VirtualDerivativeRootLineageTests.swift - The lineage of a virtual derivative names every file of its root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A virtual derivative (a subset, trim, orientation map or demultiplexed
// reads) of a root that holds several files reads every file of that root
// (`FASTQBundle.rootSequenceURLs`, lane 1x). The CLI-side lineage records,
// written by CLISequenceInputMaterialization and AssemblyInputMaterialization,
// named the one recorded file, the first chunk, while the dashboard's
// envelope named every member. They now name every member in manifest
// order, each with the same origin as before (R8, final review S1). A
// single-file root is still its one file.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class VirtualDerivativeRootLineageTests: XCTestCase {
    private var root: URL!
    private var imports: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "virtual-derivative-root-lineage")
        imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// A root bundle whose two chunks are listed in `source-files.json`, the
    /// ONT import shape, reads m1 and m2 then m3 to m5.
    private func makeMultiFileRoot() throws -> (bundle: URL, chunks: [URL]) {
        let bundle = imports.appendingPathComponent("multi.lungfishfastq", isDirectory: true)
        let chunksDirectory = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let chunks = [
            chunksDirectory.appendingPathComponent("run_0.fastq"),
            chunksDirectory.appendingPathComponent("run_1.fastq"),
        ]
        try Self.fastq(["m1", "m2"]).write(to: chunks[0], atomically: true, encoding: .utf8)
        try Self.fastq(["m3", "m4", "m5"]).write(to: chunks[1], atomically: true, encoding: .utf8)
        try Self.fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        return (bundle, chunks)
    }

    /// A virtual subset of `readIDs` of the root named `rootName` in
    /// Imports, recording `rootFASTQFilename` as its root file.
    private func makeSubset(named name: String, rootName: String, rootFASTQFilename: String, readIDs: [String]) throws -> URL {
        let subset = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: subset, withIntermediateDirectories: true)
        try (readIDs.joined(separator: "\n") + "\n")
            .write(to: subset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try Self.fastq([readIDs[0]]).write(to: subset.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "m")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/\(rootName).lungfishfastq",
                rootBundleRelativePath: "@/Imports/\(rootName).lungfishfastq",
                rootFASTQFilename: rootFASTQFilename,
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: readIDs.count, baseCount: Int64(readIDs.count * 10)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: subset
        )
        return subset
    }

    private func paths(_ urls: [URL]) -> [String] {
        urls.map(\.standardizedFileURL.path)
    }

    /// The paths among `paths` that lie inside `bundle`, in their order.
    private func paths(_ paths: [String], inside bundle: URL) -> [String] {
        let prefix = bundle.standardizedFileURL.path + "/"
        return paths.filter { $0.hasPrefix(prefix) }
    }

    /// Every lineage writer names `expectedRootFiles`, in order, as the root
    /// files of `subset`, the descriptors with the subset as their origin and
    /// the assembly records with each file as its own origin, as before.
    private func assertLineageNames(
        _ expectedRootFiles: [URL],
        of rootBundle: URL,
        for subset: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = paths(expectedRootFiles)
        let subsetPath = subset.standardizedFileURL.path

        let cli = try CLISequenceInputMaterialization.originalInputDescriptors(for: subset)
        let cliRootFiles = cli.filter { !paths([$0.path], inside: rootBundle).isEmpty }
        XCTAssertEqual(cliRootFiles.map(\.path), expected, "CLISequenceInputMaterialization", file: file, line: line)
        XCTAssertTrue(cliRootFiles.allSatisfy { $0.originPath == subsetPath && $0.checksumSHA256 != nil }, file: file, line: line)
        XCTAssertEqual(
            paths(try CLISequenceInputMaterialization.originalInputRecords(for: subset).map(\.path), inside: rootBundle),
            expected,
            "CLISequenceInputMaterialization records",
            file: file,
            line: line
        )

        let assembly = try AssemblyInputMaterialization.originalInputDescriptors(for: subset)
        let assemblyRootFiles = assembly.filter { !paths([$0.path], inside: rootBundle).isEmpty }
        XCTAssertEqual(assemblyRootFiles.map(\.path), expected, "AssemblyInputMaterialization", file: file, line: line)
        XCTAssertTrue(assemblyRootFiles.allSatisfy { $0.originPath == subsetPath && $0.checksumSHA256 != nil }, file: file, line: line)

        let records = AssemblyInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: [subset],
            executionInputURLs: [subset]
        )
        XCTAssertEqual(records.first?.originalPath, subsetPath, "the bundle aggregate comes first", file: file, line: line)
        let recordRootFiles = records.filter { !paths([$0.originalPath ?? ""], inside: rootBundle).isEmpty }
        XCTAssertEqual(recordRootFiles.compactMap(\.originalPath), expected, "AssemblyInputMaterialization records", file: file, line: line)
        XCTAssertTrue(recordRootFiles.allSatisfy { $0.sha256 != nil }, file: file, line: line)
    }

    func testTheLineageOfASubsetOfAMultiFileRootNamesEveryChunk() throws {
        let multi = try makeMultiFileRoot()
        let subset = try makeSubset(named: "multi-subset", rootName: "multi", rootFASTQFilename: "chunks/run_0.fastq", readIDs: ["m1", "m4"])
        try assertLineageNames(multi.chunks, of: multi.bundle, for: subset)
    }

    /// The dashboard recorded a chunk's bare name before lane 1x, and the
    /// materializer reads every member for it.
    func testTheLineageOfALegacyBareNameSubsetNamesEveryChunk() throws {
        let multi = try makeMultiFileRoot()
        let subset = try makeSubset(named: "legacy-subset", rootName: "multi", rootFASTQFilename: "run_0.fastq", readIDs: ["m1", "m4"])
        try assertLineageNames(multi.chunks, of: multi.bundle, for: subset)
    }

    func testTheLineageOfASubsetOfASingleFileRootStillNamesItsOneFile() throws {
        let single = imports.appendingPathComponent("single.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
        let file = single.appendingPathComponent("single.fastq")
        try Self.fastq(["s1", "s2", "s3"]).write(to: file, atomically: true, encoding: .utf8)
        let subset = try makeSubset(named: "single-subset", rootName: "single", rootFASTQFilename: "single.fastq", readIDs: ["s1", "s3"])
        try assertLineageNames([file], of: single, for: subset)
    }

    /// A root missing a member is never named as a shorter bundle, the rule
    /// the materializer refuses such a root by.
    func testTheLineageOfASubsetOfARootMissingAMemberNamesNoRootFile() throws {
        let multi = try makeMultiFileRoot()
        try FileManager.default.removeItem(at: multi.chunks[1])
        let subset = try makeSubset(named: "broken-subset", rootName: "multi", rootFASTQFilename: "chunks/run_0.fastq", readIDs: ["m1"])
        try assertLineageNames([], of: multi.bundle, for: subset)
    }
}
