// BundleResolutionCLIParityTests.swift - lungfish-cli resolves a bundle to the reads the app hands its tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// For every bundle shape, the CLI command the Operations panel records reads
/// the same files, paired the same way, as the app's own launch of that tool
/// (R3, lane 1n). The app side runs its production resolvers.
@MainActor
final class BundleResolutionCLIParityTests: XCTestCase {

    private var root: URL!
    private var shapes: ParityBundleShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bundle-resolution-cli-parity")
        shapes = try ParityBundleShapes(in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The app's classification launch resolves each sample's inputs with
    /// `AppDelegate.resolveInputFiles` and pairs them by the wizard's read
    /// plan; `lungfish-cli conda classify` must hand kraken2 the same files.
    func testCondaClassifyHandsKraken2TheFilesTheAppsClassificationLaunchDoes() async throws {
        for (shape, bundle) in shapes.all {
            let appTemp = root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true)
            let cliTemp = root.appendingPathComponent("cli-\(UUID().uuidString)/.lungfish-classify-inputs", isDirectory: true)

            let appFiles = try await AppDelegate().resolveInputFiles([bundle], tempDirectory: appTemp)
            let samples = MetagenomicsSampleGrouper.group([bundle])
            XCTAssertEqual(samples.count, 1, shape)
            let appPlan = ClassificationSampleReadPlan.plan(for: try XCTUnwrap(samples.first))

            let cliResolved = try await ClassifyCommand.resolveExecutionInputs(
                for: [bundle],
                tempDirectory: cliTemp,
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
            let cliFormat = try ClassifyCommand.parse([bundle.path, "--db", "FixtureDB"])
                .resolveReadFormat(inputURLs: [bundle]).format

            XCTAssertEqual(
                try cliResolved.executionInputURLs.map(ParityBundleShapes.readNames(in:)),
                try appFiles.map(ParityBundleShapes.readNames(in:)),
                "\(shape): the same files, in the same order"
            )
            XCTAssertEqual(cliFormat, appPlan.format, "\(shape): the same pairing")
            for (cliURL, appURL) in zip(cliResolved.executionInputURLs, appFiles)
            where !appURL.standardizedFileURL.path.hasPrefix(appTemp.standardizedFileURL.path) {
                XCTAssertEqual(cliURL.standardizedFileURL, appURL.standardizedFileURL, "\(shape): read in place")
            }
        }
    }
}

/// The bundle shapes of lane 1n's tables, in a project's `Imports` folder.
private struct ParityBundleShapes {
    let all: [(String, URL)]

    init(in imports: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        func bundle(_ name: String) throws -> URL {
            let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ names: [String], to url: URL) throws {
            try Self.fastq(names).write(to: url, atomically: true, encoding: .utf8)
        }
        func derived(
            _ url: URL,
            root: String,
            rootFile: String,
            payload: FASTQDerivativePayload,
            kind: FASTQDerivativeOperationKind,
            pairing: IngestionMetadata.PairingMode,
            format: SequenceFormat = .fastq,
            classification: ReadClassification? = nil
        ) throws {
            let operation = FASTQDerivativeOperation(kind: kind)
            try FASTQBundle.saveDerivedManifest(
                FASTQDerivedBundleManifest(
                    name: url.deletingPathExtension().lastPathComponent,
                    parentBundleRelativePath: root,
                    rootBundleRelativePath: root,
                    rootFASTQFilename: rootFile,
                    payload: payload,
                    lineage: [operation],
                    operation: operation,
                    cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                    pairingMode: pairing,
                    readClassification: classification,
                    sequenceFormat: format
                ),
                in: url
            )
        }

        let single = try bundle("single")
        try write(["s1", "s2", "s3"], to: single.appendingPathComponent("single.fastq"))

        let multi = try bundle("multi")
        let chunks = multi.appendingPathComponent("chunks", isDirectory: true)
        try fm.createDirectory(at: chunks, withIntermediateDirectories: true)
        try write(["m1", "m2"], to: chunks.appendingPathComponent("run_0.fastq"))
        try write(["m3", "m4", "m5"], to: chunks.appendingPathComponent("run_1.fastq"))
        try write(["m1"], to: multi.appendingPathComponent("preview.fastq"))
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multi)

        let oriented = try bundle("single-oriented")
        try "s1\t+\ns3\t-\n".write(to: oriented.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try write(["s1"], to: oriented.appendingPathComponent("preview.fastq"))
        try derived(
            oriented,
            root: "@/Imports/single.lungfishfastq",
            rootFile: "single.fastq",
            payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
            kind: .orient,
            pairing: .singleEnd
        )

        let paired = try bundle("paired")
        try write(["p1/1", "p2/1"], to: paired.appendingPathComponent("sample_R1.fastq"))
        try write(["p1/2", "p2/2"], to: paired.appendingPathComponent("sample_R2.fastq"))
        try derived(
            paired,
            root: ".",
            rootFile: "sample_R1.fastq",
            payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
            kind: .interleaveReformat,
            pairing: .pairedEnd
        )

        let mixed = try bundle("mixed")
        try write(["x1", "x2", "x3"], to: mixed.appendingPathComponent("merged.fastq"))
        try write(["u1/1"], to: mixed.appendingPathComponent("unmerged_R1.fastq"))
        try write(["u1/2"], to: mixed.appendingPathComponent("unmerged_R2.fastq"))
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        try derived(
            mixed,
            root: ".",
            rootFile: "merged.fastq",
            payload: .fullMixed(classification),
            kind: .pairedEndMerge,
            pairing: .pairedEnd,
            classification: classification
        )

        let fasta = try bundle("converted")
        try ">f1\nACGTACGTAC\n>f2\nACGTACGTAC\n".write(to: fasta.appendingPathComponent("converted.fasta"), atomically: true, encoding: .utf8)
        try derived(
            fasta,
            root: ".",
            rootFile: "converted.fasta",
            payload: .fullFASTA(fastaFilename: "converted.fasta"),
            kind: .translate,
            pairing: .singleEnd,
            format: .fasta
        )

        let full = try bundle("full")
        try write(["g1", "g2"], to: full.appendingPathComponent("full.fastq"))
        try derived(
            full,
            root: ".",
            rootFile: "full.fastq",
            payload: .full(fastqFilename: "full.fastq"),
            kind: .deduplicate,
            pairing: .singleEnd
        )

        all = [
            ("root single", single),
            ("root multi-file", multi),
            ("virtual orientMap", oriented),
            ("derived fullPaired", paired),
            ("derived fullMixed", mixed),
            ("derived fullFASTA", fasta),
            ("derived full", full),
        ]
    }

    static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// The record names of a FASTQ or FASTA file, in file order.
    static func readNames(in url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.first?.hasPrefix(">") == true {
            return lines.filter { $0.hasPrefix(">") }.map { String($0.dropFirst()) }
        }
        return lines.enumerated().compactMap { index, line in
            index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil
        }
    }
}
