// AssemblyReadTypeTests.swift - A derived bundle that records no platform reads the record of the bundle it derives from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 close, lane DERIVED-PLATFORM, BIO ruling DEMUX-C-BIO (S2). Every bundle an operation made (a subsample, a
// trim, a filter) recorded no sequencing platform and no assembly read type, although its source does. Map and
// Assemble then fell back to the read lengths, and an ONT subset whose reads are all 600 bases or shorter got the
// Illumina class. The two detectors now read the record of the bundle a derivative derives from when the bundle's own
// sidecar holds neither field, so the derived bundles already in projects resolve too.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class AssemblyReadTypeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-read-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    private var imports: URL { folder.appendingPathComponent("Project.lungfish/Imports", isDirectory: true) }

    /// Eight reads of 300 to 550 bases whose names match no platform. By length alone they read as Illumina.
    private static let readsText: String = [300, 340, 380, 420, 460, 500, 520, 550].enumerated().map { index, length in
        let sequence = String(repeating: "ACGTTGCA", count: length / 8 + 1).prefix(length)
        return "@read_\(index)\n\(sequence)\n+\n\(String(repeating: "I", count: length))\n"
    }.joined()

    /// A root that records its platform on its primary file's sidecar, as an ONT directory import does.
    private func makeRoot(platform: SequencingPlatform?, readType: FASTQAssemblyReadType?) throws -> URL {
        let bundle = imports.appendingPathComponent("ont-run.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try Data(Self.readsText.utf8).write(to: reads)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform, assemblyReadType: readType), for: reads)
        return bundle
    }

    /// A derived bundle whose sidecar records nothing. `rootPath` is what its manifest names as its root.
    private func makeDerived(
        named name: String,
        parent: URL,
        rootPath: String,
        payload: FASTQDerivativePayload,
        readsFile: String
    ) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(Self.readsText.utf8).write(to: bundle.appendingPathComponent(readsFile))
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: rootPath,
                rootFASTQFilename: "reads.fastq",
                payload: payload,
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 8, baseCount: 3_070),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// The premises every case shares. The derived bundle holds no record of its own, and its reads alone say
    /// Illumina, so only the record of the bundle it derives from can say ONT.
    private func assertNoRecordOfItsOwnAndShortReadsByLength(_ derived: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let primary = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: derived), file: file, line: line)
        let own = FASTQMetadataStore.load(for: primary)
        XCTAssertNil(own?.sequencingPlatform, file: file, line: line)
        XCTAssertNil(own?.assemblyReadType, file: file, line: line)
        XCTAssertEqual(AssemblyReadType.lengthDefault(forInputURL: derived), .illuminaShortReads, file: file, line: line)
        XCTAssertEqual(MappingReadClass.lengthDefault(forInputURL: derived), .illuminaShortReads, file: file, line: line)
    }

    // MARK: - Tests

    /// BIO's test. A virtual derivative (a read ID list over its root) names the ONT root in its manifest.
    func testDerivedBundleWithoutRecordReadsRootRecord() throws {
        let root = try makeRoot(platform: .oxfordNanopore, readType: .ontReads)
        let derived = try makeDerived(
            named: "ont-run-subset",
            parent: root,
            rootPath: "@/Imports/\(root.lastPathComponent)",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            readsFile: "preview.fastq"
        )
        try assertNoRecordOfItsOwnAndShortReadsByLength(derived)

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: derived), .ontReads)
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: derived), .ontReads)
    }

    /// The shape builds up to 12859 wrote for a subsample or a filter. It stores its full reads, so its manifest
    /// names itself as its root (".") and only the parent path leads to the ONT bundle.
    func testAMaterializedDerivativeOfBuild12859ReadsItsParentRecord() throws {
        let root = try makeRoot(platform: .oxfordNanopore, readType: .ontReads)
        let derived = try makeDerived(
            named: "ont-run-subsampleCount",
            parent: root,
            rootPath: ".",
            payload: .full(fastqFilename: "reads.fastq"),
            readsFile: "reads.fastq"
        )
        try assertNoRecordOfItsOwnAndShortReadsByLength(derived)

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: derived), .ontReads)
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: derived), .ontReads)
    }

    /// A trim of that subsample has a parent that records nothing either. The lookup goes on up to the record.
    func testAGrandchildReadsTheRecordTwoGenerationsUp() throws {
        let root = try makeRoot(platform: .oxfordNanopore, readType: .ontReads)
        let child = try makeDerived(
            named: "ont-run-subsampleCount",
            parent: root,
            rootPath: ".",
            payload: .full(fastqFilename: "reads.fastq"),
            readsFile: "reads.fastq"
        )
        let grandchild = try makeDerived(
            named: "ont-run-subsampleCount-trimmed",
            parent: child,
            rootPath: ".",
            payload: .full(fastqFilename: "reads.fastq"),
            readsFile: "reads.fastq"
        )
        try assertNoRecordOfItsOwnAndShortReadsByLength(grandchild)

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: grandchild), .ontReads)
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: grandchild), .ontReads)
    }

    /// The lookup applies only when the bundle's own sidecar holds neither field. A person's own record of the
    /// derived bundle stays the answer.
    func testARecordOfItsOwnBeatsTheRecordOfTheBundleItDerivesFrom() throws {
        let root = try makeRoot(platform: .oxfordNanopore, readType: .ontReads)
        let derived = try makeDerived(
            named: "ont-run-subsampleCount",
            parent: root,
            rootPath: ".",
            payload: .full(fastqFilename: "reads.fastq"),
            readsFile: "reads.fastq"
        )
        let primary = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: derived))
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .illumina), for: primary)

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: derived), .illuminaShortReads)
        XCTAssertEqual(MappingReadClass.detect(fromInputURL: derived), .illuminaShortReads)
    }

    /// A derived bundle of a root that records nothing still answers nil, so the wizards keep their length default.
    func testADerivedBundleOfAnUnrecordedRootStaysUndecided() throws {
        let root = try makeRoot(platform: nil, readType: nil)
        let derived = try makeDerived(
            named: "ont-run-subsampleCount",
            parent: root,
            rootPath: ".",
            payload: .full(fastqFilename: "reads.fastq"),
            readsFile: "reads.fastq"
        )
        XCTAssertNil(AssemblyReadType.detect(fromInputURL: derived))
        XCTAssertNil(MappingReadClass.detect(fromInputURL: derived))
    }
}
