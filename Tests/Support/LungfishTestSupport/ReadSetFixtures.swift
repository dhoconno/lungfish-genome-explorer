// ReadSetFixtures.swift - One FASTQ bundle of every read layout the read-set resolver plans
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The layouts are the L1 to L6 rows of docs/contracts/READ-PAIRING.md.
// Read names say what each read is: s single-end, i interleaved mate,
// m merged, p pair mate, x merged in a merge derivative, u unmerged mate,
// r repaired mate, o orphan, g full derivative read.

import Foundation
import LungfishIO
import LungfishWorkflow

public struct ReadSetFixtures: Sendable {
    public let projectURL: URL
    public let importsURL: URL

    /// L1, a root with one single-end file, reads s1 to s3.
    public let singleRoot: URL
    /// L2, a root with one strictly interleaved file, pairs i1 and i2.
    public let interleavedRoot: URL
    /// L3, a root file of merged reads m1 to m3 then pairs p1 and p2, whose
    /// sidecar records the classification with every role naming the file.
    public let mixedRoot: URL
    /// L4, a chunked root, chunk run_0 (c1, c2) then run_1 (c3).
    public let chunkedRoot: URL
    /// L4 from an Oxford Nanopore import whose two chunks are named `x_1`
    /// and `x_2`, which the file-name rule would call mates.
    public let nanoporeChunkedRoot: URL
    /// L4 of an Illumina run whose two chunks are named as R1 and R2.
    public let namedPairChunkedRoot: URL
    /// L4 whose sidecar records no known platform (`unknown`) and whose two
    /// chunks are named `x_1` and `x_2`.
    public let unknownPlatformChunkedRoot: URL
    /// L5a, a `full` derivative of single reads g1 and g2.
    public let fullDerivative: URL
    /// L5a, a `full` derivative of a re-imported `fastq merge` output:
    /// merged reads m1 and m2, then pair p1, with a sidecar in the L3 form.
    public let fullMergeOutput: URL
    /// L5a, a `full` derivative whose file is strictly interleaved and has
    /// no sidecar, so it is scanned as before.
    public let fullUnlabelled: URL
    /// L5b, a `fullPaired` derivative, R1 (p1/1, p2/1) and R2 (p1/2, p2/2).
    public let pairedDerivative: URL
    /// L5c, a merge derivative: merged x1 to x3 and the unmerged pair u1.
    public let mergeDerivative: URL
    /// L5d, a repair derivative: pairs r1 and r2 and the orphan o1.
    public let repairDerivative: URL
    /// L5e, a `fullFASTA` derivative, records f1 and f2.
    public let fastaDerivative: URL
    /// L6a, a virtual subset of ``singleRoot`` (s1, s3).
    public let subsetOfSingle: URL
    /// L6a, a virtual subset of ``interleavedRoot`` (pair i1).
    public let subsetOfInterleaved: URL
    /// L6a, a virtual subset of ``mergeDerivative`` (pair u1, merged x1).
    public let subsetOfMerge: URL
    /// L6a, a virtual subset of ``repairDerivative`` holding only pairs
    /// r1 and r2. Its lineage names only `repair`.
    public let subsetOfRepair: URL
    /// L6e, a demultiplex group, which holds no reads of its own.
    public let demuxGroup: URL

    /// What the stub materializer writes for each virtual bundle.
    public let materializedReads: [String: String]

    /// A materializer that writes ``materializedReads`` for a bundle and
    /// throws for any other.
    public var materializer: StubMaterializer {
        StubMaterializer(readsByBundlePath: materializedReads)
    }

    public init(in directory: URL) throws {
        let fm = FileManager.default
        projectURL = directory.appendingPathComponent("ReadSets.lungfish", isDirectory: true)
        importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        try fm.createDirectory(at: importsURL, withIntermediateDirectories: true)
        let imports = importsURL
        func bundle(_ name: String) throws -> URL {
            let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ names: [String], to url: URL) throws {
            try Self.fastq(names).write(to: url, atomically: true, encoding: .utf8)
        }
        func sidecar(_ fileURL: URL, pairing: IngestionMetadata.PairingMode? = nil, classification: ReadClassification? = nil, platform: SequencingPlatform? = nil) {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(
                    ingestion: pairing.map { IngestionMetadata(pairingMode: $0, pairingSource: .detected) },
                    readClassification: classification,
                    sequencingPlatform: platform
                ),
                for: fileURL
            )
        }

        singleRoot = try bundle("single")
        try write(["s1", "s2", "s3"], to: singleRoot.appendingPathComponent("single.fastq"))

        interleavedRoot = try bundle("interleaved")
        let interleavedFile = interleavedRoot.appendingPathComponent("reads.fastq")
        try write(["i1/1", "i1/2", "i2/1", "i2/2"], to: interleavedFile)
        sidecar(interleavedFile, pairing: .interleaved)

        mixedRoot = try bundle("mixed-root")
        let mixedRootFile = mixedRoot.appendingPathComponent("reads.fastq")
        try write(["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"], to: mixedRootFile)
        sidecar(mixedRootFile, pairing: .interleaved, classification: Self.singleFileClassification("reads.fastq", merged: 3, pairs: 2))

        chunkedRoot = try bundle("chunked")
        try Self.chunks(in: chunkedRoot, [("run_0.fastq", ["c1", "c2"]), ("run_1.fastq", ["c3"])])

        nanoporeChunkedRoot = try bundle("nanopore")
        let nanoporeChunks = try Self.chunks(in: nanoporeChunkedRoot, [("x_1.fastq", ["o-a", "o-b"]), ("x_2.fastq", ["o-c"])])
        sidecar(nanoporeChunks[0], platform: .oxfordNanopore)

        namedPairChunkedRoot = try bundle("named-pair")
        let namedPairChunks = try Self.chunks(in: namedPairChunkedRoot, [("sample_R1.fastq", ["q1/1"]), ("sample_R2.fastq", ["q1/2"])])
        sidecar(namedPairChunks[0], platform: .illumina)

        unknownPlatformChunkedRoot = try bundle("unknown-platform")
        let unknownChunks = try Self.chunks(in: unknownPlatformChunkedRoot, [("x_1.fastq", ["v1"]), ("x_2.fastq", ["v2"])])
        sidecar(unknownChunks[0], platform: .unknown)

        fullDerivative = try bundle("full")
        try write(["g1", "g2"], to: fullDerivative.appendingPathComponent("reads.fastq"))
        try Self.derivedManifest(in: fullDerivative, parent: ".", payload: .full(fastqFilename: "reads.fastq"), kind: .deduplicate, pairing: .singleEnd)

        fullMergeOutput = try bundle("merge-output")
        let mergeOutputFile = fullMergeOutput.appendingPathComponent("reads.fastq")
        try write(["m1", "m2", "p1/1", "p1/2"], to: mergeOutputFile)
        sidecar(mergeOutputFile, pairing: .interleaved, classification: Self.singleFileClassification("reads.fastq", merged: 2, pairs: 1))
        try Self.derivedManifest(in: fullMergeOutput, parent: ".", payload: .full(fastqFilename: "reads.fastq"), kind: .deduplicate, pairing: .interleaved)

        fullUnlabelled = try bundle("unlabelled")
        try write(["k1/1", "k1/2", "k2/1", "k2/2"], to: fullUnlabelled.appendingPathComponent("reads.fastq"))
        try Self.derivedManifest(in: fullUnlabelled, parent: ".", payload: .full(fastqFilename: "reads.fastq"), kind: .deduplicate, pairing: .interleaved)

        pairedDerivative = try bundle("paired")
        try write(["p1/1", "p2/1"], to: pairedDerivative.appendingPathComponent("sample_R1.fastq"))
        try write(["p1/2", "p2/2"], to: pairedDerivative.appendingPathComponent("sample_R2.fastq"))
        try Self.derivedManifest(in: pairedDerivative, parent: ".", payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"), kind: .interleaveReformat, pairing: .pairedEnd)

        mergeDerivative = try bundle("merge")
        try write(["x1", "x2", "x3"], to: mergeDerivative.appendingPathComponent("merged.fastq"))
        try write(["u1/1"], to: mergeDerivative.appendingPathComponent("unmerged_R1.fastq"))
        try write(["u1/2"], to: mergeDerivative.appendingPathComponent("unmerged_R2.fastq"))
        let mergeClassification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        try Self.derivedManifest(in: mergeDerivative, parent: ".", payload: .fullMixed(mergeClassification), kind: .pairedEndMerge, pairing: .pairedEnd, classification: mergeClassification)

        repairDerivative = try bundle("repair")
        try write(["r1/1", "r2/1"], to: repairDerivative.appendingPathComponent("repaired_R1.fastq"))
        try write(["r1/2", "r2/2"], to: repairDerivative.appendingPathComponent("repaired_R2.fastq"))
        try write(["o1"], to: repairDerivative.appendingPathComponent("singletons.fastq"))
        let repairClassification = ReadClassification(files: [
            .init(filename: "repaired_R1.fastq", role: .pairedR1, readCount: 2),
            .init(filename: "repaired_R2.fastq", role: .pairedR2, readCount: 2),
            .init(filename: "singletons.fastq", role: .unpaired, readCount: 1),
        ])
        // A repair derivative's manifest carries no read classification, only
        // its payload roles, as the GUI repair wrote it.
        try Self.derivedManifest(in: repairDerivative, parent: ".", payload: .fullMixed(repairClassification), kind: .pairedEndRepair, pairing: .pairedEnd)

        fastaDerivative = try bundle("converted")
        try ">f1\nACGTACGTAC\n>f2\nACGTACGTAC\n".write(to: fastaDerivative.appendingPathComponent("converted.fasta"), atomically: true, encoding: .utf8)
        try Self.derivedManifest(in: fastaDerivative, parent: ".", payload: .fullFASTA(fastaFilename: "converted.fasta"), kind: .translate, pairing: .singleEnd, format: .fasta)

        func subset(_ name: String, of parent: URL, kind: FASTQDerivativeOperationKind, lineage: [FASTQDerivativeOperationKind]) throws -> URL {
            let url = try bundle(name)
            try "id\n".write(to: url.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
            try write(["preview"], to: url.appendingPathComponent("preview.fastq"))
            try Self.derivedManifest(
                in: url,
                parent: "@/Imports/\(parent.lastPathComponent)",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                kind: kind,
                pairing: nil,
                lineage: lineage
            )
            return url
        }
        subsetOfSingle = try subset("single-subset", of: singleRoot, kind: .lengthFilter, lineage: [.lengthFilter])
        subsetOfInterleaved = try subset("interleaved-subset", of: interleavedRoot, kind: .lengthFilter, lineage: [.lengthFilter])
        subsetOfMerge = try subset("merge-subset", of: mergeDerivative, kind: .lengthFilter, lineage: [.lengthFilter])
        subsetOfRepair = try subset("repair-subset", of: repairDerivative, kind: .lengthFilter, lineage: [.pairedEndRepair, .lengthFilter])

        demuxGroup = try bundle("demux-group")
        try Self.derivedManifest(in: demuxGroup, parent: ".", payload: .demuxGroup(barcodeCount: 2), kind: .demultiplex, pairing: nil)

        materializedReads = [
            subsetOfSingle.standardizedFileURL.path: Self.fastq(["s1", "s3"]),
            subsetOfInterleaved.standardizedFileURL.path: Self.fastq(["i1/1", "i1/2"]),
            subsetOfMerge.standardizedFileURL.path: Self.fastq(["u1/1", "u1/2", "x1"]),
            subsetOfRepair.standardizedFileURL.path: Self.fastq(["r1/1", "r1/2", "r2/1", "r2/2"]),
        ]
    }

    // MARK: - Helpers

    public static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// The record names of a FASTQ file, in file order.
    public static func readNames(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }

    /// The sidecar classification of a file that mixes kinds of records,
    /// every role naming that file, as a merge recipe records it.
    static func singleFileClassification(_ filename: String, merged: Int, pairs: Int) -> ReadClassification {
        ReadClassification(files: [
            .init(filename: filename, role: .merged, readCount: merged),
            .init(filename: filename, role: .pairedR1, readCount: pairs),
            .init(filename: filename, role: .pairedR2, readCount: pairs),
        ])
    }

    @discardableResult
    static func chunks(in bundleURL: URL, _ files: [(name: String, reads: [String])]) throws -> [URL] {
        let directory = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            try fastq(file.reads).write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        try fastq([files[0].reads[0]]).write(to: bundleURL.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: files.map {
            .init(filename: "chunks/\($0.name)", originalPath: "/orig/\($0.name)", sizeBytes: 1, isSymlink: false)
        }).save(to: bundleURL)
        return urls
    }

    static func derivedManifest(
        in bundle: URL,
        parent: String,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode?,
        format: SequenceFormat = .fastq,
        classification: ReadClassification? = nil,
        lineage: [FASTQDerivativeOperationKind]? = nil
    ) throws {
        let operation = FASTQDerivativeOperation(kind: kind)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: bundle.deletingPathExtension().lastPathComponent,
                parentBundleRelativePath: parent,
                rootBundleRelativePath: parent,
                rootFASTQFilename: "reads.fastq",
                payload: payload,
                lineage: (lineage ?? [kind]).map { FASTQDerivativeOperation(kind: $0) },
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: pairing,
                readClassification: classification,
                sequenceFormat: format
            ),
            in: bundle
        )
    }

    /// Writes fixed reads for each virtual bundle it knows and throws for
    /// any other, the way the real materializer refuses a demultiplex group.
    public struct StubMaterializer: CLISequenceInputMaterializing, Sendable {
        public struct Unsupported: Error, Equatable {
            public let bundlePath: String
        }

        public let readsByBundlePath: [String: String]

        public init(readsByBundlePath: [String: String]) {
            self.readsByBundlePath = readsByBundlePath
        }

        public func materialize(
            bundleURL: URL,
            tempDirectory: URL,
            progress: (@Sendable (String) -> Void)?
        ) async throws -> URL {
            let path = bundleURL.standardizedFileURL.path
            guard let reads = readsByBundlePath[path] else { throw Unsupported(bundlePath: path) }
            let output = tempDirectory.appendingPathComponent("materialized-\(UUID().uuidString).fastq")
            try reads.write(to: output, atomically: true, encoding: .utf8)
            return output
        }
    }
}
