// FASTQDerivativeMaterializationTests.swift - A derived bundle exports to the reads it describes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Projects made before the FASTQ operations dialog hold virtual derivatives, a
// trim or a demultiplexed subset that point at their root file and name the
// reads, the trim positions and the orientation to apply. The app exports one
// to a FASTQ or FASTA file with `FASTQDerivativeService.exportMaterializedFASTQ`
// (the sidebar's Export) and materializes it with `materializeDatasetFASTQ`
// (Reassemble and the classifier launches). Every bundle here is written by
// hand, because the app makes no virtual derivative any more.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQDerivativeMaterializationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDerivativeMaterialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A bundle folder named `name` with its payload file `fastqFilename` still to write.
    private func makeBundle(
        named name: String,
        fastqFilename: String = "reads.fastq"
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = tempDir.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (bundleURL, bundleURL.appendingPathComponent(fastqFilename))
    }

    private func writeFASTQ(records: [(id: String, description: String?, sequence: String)], to url: URL) throws {
        let lines: [String] = records.flatMap { record in
            let header = record.description.map { "@\(record.id) \($0)" } ?? "@\(record.id)"
            return [header, record.sequence, "+", String(repeating: "I", count: record.sequence.count)]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeFASTA(records: [(id: String, description: String?, sequence: String)], to url: URL) throws {
        let lines: [String] = records.flatMap { record in
            let header = record.description.map { ">\(record.id) \($0)" } ?? ">\(record.id)"
            return [header, record.sequence]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func gzipFile(_ inputURL: URL, to outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", inputURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let compressed = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !compressed.isEmpty else {
            let detail = String(data: stderrData, encoding: .utf8) ?? "gzip failed"
            throw XCTSkip("Unable to create gzip fixture: \(detail)")
        }

        try compressed.write(to: outputURL, options: .atomic)
    }

    func testATrimmedBundleExportsItsTrimmedReads() async throws {
        let root = try makeBundle(named: "root")
        try writeFASTQ(
            records: [
                (id: "read1", description: nil, sequence: "AACCGGTTAA"),
                (id: "read2", description: nil, sequence: "TTGGCCAA"),
            ],
            to: root.fastqURL
        )

        let trimmedBundle = tempDir.appendingPathComponent("root-trim.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: trimmedBundle, withIntermediateDirectories: true)
        try FASTQTrimPositionFile.write(
            [
                FASTQTrimRecord(readID: "read1", trimStart: 2, trimEnd: 9),
                FASTQTrimRecord(readID: "read2", trimStart: 1, trimEnd: 6),
            ],
            to: trimmedBundle.appendingPathComponent(FASTQBundle.trimPositionFilename)
        )
        let trimOperation = FASTQDerivativeOperation(kind: .fixedTrim, trimFrom5Prime: 2, trimFrom3Prime: 1)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "root-trim",
                parentBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
                rootBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
                rootFASTQFilename: root.fastqURL.lastPathComponent,
                payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
                lineage: [trimOperation],
                operation: trimOperation,
                cachedStatistics: .empty,
                pairingMode: .singleEnd
            ),
            in: trimmedBundle
        )

        let exportURL = tempDir.appendingPathComponent("trimmed.fastq")
        try await FASTQDerivativeService().exportMaterializedFASTQ(fromDerivedBundle: trimmedBundle, to: exportURL)

        XCTAssertEqual(
            try String(contentsOf: exportURL, encoding: .utf8),
            "@read1\nCCGGTTA\n+\nIIIIIII\n@read2\nTGGCC\n+\nIIIII\n"
        )
    }

    func testADemultiplexedVirtualBundleExportsItsTrimmedOrientedReadsWithTheirDescription() async throws {
        let root = try makeBundle(named: "root")
        try writeFASTQ(
            records: [(id: "read1", description: "runid=abc sample=demo", sequence: "AACCGGTTAA")],
            to: root.fastqURL
        )

        let demuxBundle = tempDir.appendingPathComponent("root-demux.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: demuxBundle, withIntermediateDirectories: true)
        try "read1\n".write(
            to: demuxBundle.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #format lungfish-demux-trim-v1
        read_id\tmate\ttrim_5p\ttrim_3p
        read1 rc\t0\t2\t1
        """.write(
            to: demuxBundle.appendingPathComponent(FASTQBundle.trimPositionFilename),
            atomically: true,
            encoding: .utf8
        )
        try "read1\t-\n".write(
            to: demuxBundle.appendingPathComponent("orient-map.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let demuxOperation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: "cutadapt")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "root-demux",
                parentBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
                rootBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
                rootFASTQFilename: root.fastqURL.lastPathComponent,
                payload: .demuxedVirtual(
                    barcodeID: "bc01",
                    readIDListFilename: "read-ids.txt",
                    previewFilename: "preview.fastq.gz",
                    trimPositionsFilename: FASTQBundle.trimPositionFilename,
                    orientMapFilename: "orient-map.tsv"
                ),
                lineage: [demuxOperation],
                operation: demuxOperation,
                cachedStatistics: .empty,
                pairingMode: .singleEnd
            ),
            in: demuxBundle
        )

        let exportURL = tempDir.appendingPathComponent("demux.fastq")
        try await FASTQDerivativeService().exportMaterializedFASTQ(fromDerivedBundle: demuxBundle, to: exportURL)

        XCTAssertEqual(
            try String(contentsOf: exportURL, encoding: .utf8),
            "@read1 runid=abc sample=demo\nTAACCGG\n+\nIIIIIII\n"
        )
    }

    func testADemultiplexedVirtualBundleOfFASTAExportsAsFASTA() async throws {
        let rootBundleURL = tempDir.appendingPathComponent("root-fasta.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundleURL, withIntermediateDirectories: true)
        let rootFASTAURL = rootBundleURL.appendingPathComponent("reads.fasta")
        try writeFASTA(
            records: [(id: "read1", description: "runid=abc sample=demo", sequence: "AACCGGTTAA")],
            to: rootFASTAURL
        )

        let demuxBundle = tempDir.appendingPathComponent("root-fasta-demux.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: demuxBundle, withIntermediateDirectories: true)
        try "read1\n".write(
            to: demuxBundle.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FASTQTrimPositionFile.write(
            [FASTQTrimRecord(readID: "read1", trimStart: 2, trimEnd: 9)],
            to: demuxBundle.appendingPathComponent(FASTQBundle.trimPositionFilename)
        )
        try "read1\t-\n".write(
            to: demuxBundle.appendingPathComponent("orient-map.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let demuxOperation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: "cutadapt")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "root-fasta-demux",
                parentBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
                rootBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
                rootFASTQFilename: rootFASTAURL.lastPathComponent,
                payload: .demuxedVirtual(
                    barcodeID: "bc01",
                    readIDListFilename: "read-ids.txt",
                    previewFilename: "preview.fastq",
                    trimPositionsFilename: FASTQBundle.trimPositionFilename,
                    orientMapFilename: "orient-map.tsv"
                ),
                lineage: [demuxOperation],
                operation: demuxOperation,
                cachedStatistics: .placeholder(readCount: 1, baseCount: 10),
                pairingMode: .singleEnd,
                sequenceFormat: .fasta
            ),
            in: demuxBundle
        )

        let exportURL = tempDir.appendingPathComponent("demux.fasta")
        try await FASTQDerivativeService().exportMaterializedFASTQ(fromDerivedBundle: demuxBundle, to: exportURL)

        XCTAssertEqual(SequenceFormat.from(url: exportURL), .fasta)
        XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8), ">read1\nTAACCGG\n")
    }

    func testAFullGzippedPayloadMaterializesToAReadableGzipPath() async throws {
        let sourceFASTQ = tempDir.appendingPathComponent("source.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceFASTQ,
            readCount: 3,
            readLength: 24,
            idPrefix: "gzread"
        )

        let bundle = try makeBundle(named: "derived", fastqFilename: "reads.fastq.gz")
        try gzipFile(sourceFASTQ, to: bundle.fastqURL)
        let manifest = FASTQDerivedBundleManifest(
            name: "derived",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: bundle.fastqURL.lastPathComponent,
            payload: .full(fastqFilename: bundle.fastqURL.lastPathComponent),
            lineage: [
                FASTQDerivativeOperation(kind: .subsampleProportion, proportion: 1.0)
            ],
            operation: FASTQDerivativeOperation(kind: .subsampleProportion, proportion: 1.0),
            cachedStatistics: .placeholder(readCount: 3, baseCount: 72),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle.bundleURL)

        let outDir = tempDir.appendingPathComponent("materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let materializedURL = try await FASTQDerivativeService().materializeDatasetFASTQ(
            fromBundle: bundle.bundleURL,
            tempDirectory: outDir,
            progress: nil
        )

        XCTAssertTrue(
            materializedURL.lastPathComponent.hasSuffix(".fastq.gz"),
            "Materialized gzip payload should keep a .fastq.gz suffix so FASTQ readers and tools treat it as compressed"
        )
        let records = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.map(\.identifier), ["gzread1", "gzread2", "gzread3"])
    }

    func testExportRefusesABundleThatIsNotDerived() async throws {
        let plain = try makeBundle(named: "plain")
        try writeFASTQ(records: [(id: "read1", description: nil, sequence: "ACGT")], to: plain.fastqURL)
        let exportURL = tempDir.appendingPathComponent("plain.fastq")

        do {
            try await FASTQDerivativeService().exportMaterializedFASTQ(fromDerivedBundle: plain.bundleURL, to: exportURL)
            XCTFail("a bundle with no derived manifest has nothing to export")
        } catch FASTQDerivativeError.derivedManifestMissing {
            XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
        }
    }
}
