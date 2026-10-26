// MappingPooledInputsFixture.swift - The pooled bundles of check C2, built in the test
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane MAPPOOL (obs-13, BIO-C2). The fixture of check C2 is one
// 4000 bp contig `refC2` and bundles of interleaved pairs named `a1/1`, `a1/2`
// and so on. Every read is 100 bp on a 250 bp fragment, so a real pair maps
// 150 bp apart on one contig and a pair made of reads from two bundles maps
// about 1900 bp apart. The classes MappingPooledInputsTests and
// MappingPooledInputsConformanceTests share it, and neither depends on the
// scratchpad generator of the check.

import Foundation
import LungfishTestSupport
@testable import LungfishIO

enum MappingPooledInputsFixture {
    static let contigName = "refC2"
    static let readLength = 100
    static let fragmentLength = 250

    /// Fragment starts (1-based) of bundle A, four pairs.
    static let bundleAStarts = [101, 401, 701, 901]
    /// Fragment starts of bundle B, four pairs.
    static let bundleBStarts = [2001, 2301, 2601, 2901]
    /// Fragment starts of a third bundle, four pairs.
    static let bundleCStarts = [1201, 1501, 3201, 3501]
    /// Fragment starts of a bundle of six pairs (lead L1, unequal sizes).
    static let bundleBLongStarts = bundleBStarts + [3201, 3501]

    /// The contig, 4000 bases of a seeded generator, so every run maps the same reads.
    static let reference: [UInt8] = {
        let bases = Array("ACGT".utf8)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<4000).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            return bases[Int(mixed >> 62)]
        }
    }()

    static func writeReference(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("refC2.fa")
        let sequence = String(decoding: reference, as: UTF8.self)
        try ">\(contigName)\n\(sequence)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Interleaved pairs named `<prefix>1/1`, `<prefix>1/2`, `<prefix>2/1` and so on,
    /// one per fragment start. R1 is the forward strand at the start and R2 is the
    /// reverse complement of the fragment's last 100 bases.
    static func interleavedFASTQ(prefix: String, starts: [Int]) -> String {
        var text = ""
        for (index, start) in starts.enumerated() {
            let fragment = Array(reference[(start - 1)..<(start - 1 + fragmentLength)])
            let name = "\(prefix)\(index + 1)"
            text += record("\(name)/1", Array(fragment.prefix(readLength)))
            text += record("\(name)/2", reverseComplement(Array(fragment.suffix(readLength))))
        }
        return text
    }

    /// Single reads named `<prefix>1`, `<prefix>2` and so on, forward at each start.
    static func singleReadsFASTQ(prefix: String, starts: [Int]) -> String {
        starts.enumerated().map { index, start in
            record("\(prefix)\(index + 1)", Array(reference[(start - 1)..<(start - 1 + readLength)]))
        }.joined()
    }

    /// The leftmost position every read of `starts` maps to, sorted.
    static func expectedPositions(_ starts: [Int]...) -> [Int] {
        starts.flatMap { $0 }.flatMap { [$0, $0 + fragmentLength - readLength] }.sorted()
    }

    /// The R1 and R2 halves of an interleaved text.
    static func splitInterleaved(_ text: String) -> (r1: String, r2: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        var first: [Substring] = []
        var second: [Substring] = []
        for (index, line) in lines.enumerated() {
            if (index / 4) % 2 == 0 { first.append(line) } else { second.append(line) }
        }
        return (first.joined(separator: "\n") + "\n", second.joined(separator: "\n") + "\n")
    }

    /// `<directory>/<name>.lungfishfastq/<name>.fastq`, the bundle of one import.
    /// With `gzipped` the payload is `<name>.fastq.gz`, as a physical import keeps
    /// it, written with `/usr/bin/gzip`.
    /// With `platform` the file's sidecar records that sequencing platform, as an
    /// import does.
    @discardableResult
    static func writeBundle(
        named name: String,
        fastq: String,
        in directory: URL,
        gzipped: Bool = false,
        platform: SequencingPlatform? = nil
    ) throws -> URL {
        let bundle = try writeBundlePayload(named: name, fastq: fastq, in: directory, gzipped: gzipped)
        if let platform {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(ingestion: nil, readClassification: nil, sequencingPlatform: platform),
                for: fastqURL(in: bundle)
            )
        }
        return bundle
    }

    private static func writeBundlePayload(named name: String, fastq: String, in directory: URL, gzipped: Bool) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plain = bundle.appendingPathComponent("\(name).fastq")
        try fastq.write(to: plain, atomically: true, encoding: .utf8)
        if gzipped {
            let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-f", plain.path], timeout: 30)
            guard result.status == 0 else {
                throw NSError(
                    domain: "MappingPooledInputsFixture",
                    code: Int(result.status),
                    userInfo: [NSLocalizedDescriptionKey: "gzip failed: \(result.stderr)"]
                )
            }
        }
        return bundle
    }

    /// The FASTQ file ``writeBundle(named:fastq:in:gzipped:)`` wrote, the `.fastq.gz`
    /// when the bundle holds one and the `.fastq` otherwise.
    static func fastqURL(in bundle: URL) -> URL {
        let plain = bundle.appendingPathComponent("\(bundle.deletingPathExtension().lastPathComponent).fastq")
        let gzip = plain.appendingPathExtension("gz")
        return FileManager.default.fileExists(atPath: gzip.path) ? gzip : plain
    }

    /// A bundle that holds an R1 file and an R2 file (a paired import listed in
    /// `source-files.json`), as ResolvedSequenceInputsTests builds one. Returns
    /// the bundle and its two files, R1 first.
    ///
    /// With `platform` the R1 file's sidecar records that platform, as a paired
    /// import does. The read-set plan pairs two chunks named as R1 and R2 only
    /// for a short-read platform (`docs/contracts/READ-PAIRING.md`, L4).
    static func writeMateFileBundle(
        named name: String,
        interleaved: String,
        in directory: URL,
        platform: SequencingPlatform? = nil
    ) throws -> (bundle: URL, files: [URL]) {
        let written = try writeMateFilePayload(named: name, interleaved: interleaved, in: directory)
        if let platform {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(ingestion: nil, readClassification: nil, sequencingPlatform: platform),
                for: written.files[0]
            )
        }
        return written
    }

    private static func writeMateFilePayload(
        named name: String,
        interleaved: String,
        in directory: URL
    ) throws -> (bundle: URL, files: [URL]) {
        let bundle = directory.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let halves = splitInterleaved(interleaved)
        var files: [URL] = []
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for (suffix, text) in [("R1", halves.r1), ("R2", halves.r2)] {
            let file = chunks.appendingPathComponent("\(name)_\(suffix).fastq")
            try text.write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
            entries.append(.init(
                filename: "chunks/\(file.lastPathComponent)",
                originalPath: "/orig/\(file.lastPathComponent)",
                sizeBytes: 1,
                isSymlink: false
            ))
        }
        let firstRecord = halves.r1.split(separator: "\n", omittingEmptySubsequences: false).prefix(4).joined(separator: "\n") + "\n"
        try firstRecord.write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return (bundle, files)
    }

    private static func record(_ name: String, _ bases: [UInt8]) -> String {
        "@\(name)\n\(String(decoding: bases, as: UTF8.self))\n+\n\(String(repeating: "I", count: bases.count))\n"
    }

    private static func reverseComplement(_ bases: [UInt8]) -> [UInt8] {
        bases.reversed().map { base in
            switch base {
            case UInt8(ascii: "A"): return UInt8(ascii: "T")
            case UInt8(ascii: "C"): return UInt8(ascii: "G")
            case UInt8(ascii: "G"): return UInt8(ascii: "C")
            default: return UInt8(ascii: "A")
            }
        }
    }
}
