// BundleCountedOnceFixtures.swift - The two roots whose inputs must be counted once (BIO-BUNDLE-COUNTED-TWICE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The two `.lungfishfastq` roots of the ruling BIO-BUNDLE-COUNTED-TWICE, built as its measure builds them.
/// Every read is cut from one 600-base reference, so a mapper maps all of them, and every root is a real
/// folder with no manifest beyond the one a chunked root writes.
///
/// A chunked root is what an Oxford Nanopore import and Merge Into New Bundle write: `chunks/c<i>.fastq`
/// listed in `source-files.json`, no recorded platform. A paired root holds `s_R1.fastq` and `s_R2.fastq`
/// with the mates named `<name>p<i> 1:N:0:A` and `<name>p<i> 2:N:0:A`.
public enum BundleCountedOnceFixtures {
    /// A root of chunk files and the paths of its chunks, all standardized.
    public struct ChunkedRoot {
        public let root: URL
        public let chunks: [URL]
    }

    /// A root of an R1 and an R2 file, all standardized.
    public struct PairedRoot {
        public let root: URL
        public let r1: URL
        public let r2: URL
    }

    /// 600 pseudo-random bases, the same every time.
    public static func reference() -> String {
        var state: UInt64 = 7
        let bases = Array("ACGT")
        var text = ""
        for _ in 0..<600 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            text.append(bases[Int((state >> 33) % 4)])
        }
        return text
    }

    /// `chunks` files of `readsPerChunk` reads of 80 bases each, cut 30 bases apart (at most 12 reads in all).
    public static func chunkedRoot(
        named name: String,
        in parent: URL,
        chunks: Int,
        readsPerChunk: Int
    ) throws -> ChunkedRoot {
        precondition(chunks * readsPerChunk <= 12, "the reference holds 12 reads cut 30 bases apart")
        let reference = Array(reference())
        let bundle = parent.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        let folder = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        var entries: [[String: Any]] = []
        var number = 0
        for index in 0..<chunks {
            let url = folder.appendingPathComponent("c\(index).fastq")
            var text = ""
            for _ in 0..<readsPerChunk {
                let start = 20 + number * 30
                text += record("read\(number)", String(reference[start..<start + 80]))
                number += 1
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url.standardizedFileURL)
            entries.append([
                "filename": "chunks/c\(index).fastq",
                "originalPath": url.path,
                "sizeBytes": text.utf8.count,
                "isSymlink": false,
            ])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["version": 1, "files": entries])
        try manifest.write(to: bundle.appendingPathComponent("source-files.json"), options: .atomic)
        return ChunkedRoot(root: bundle.standardizedFileURL, chunks: urls)
    }

    /// `pairs` pairs: R1 is 60 bases cut 100 bases apart, R2 the reverse complement of 60 bases 140 on (at most 4 pairs).
    public static func pairedRoot(named name: String, in parent: URL, pairs: Int) throws -> PairedRoot {
        precondition(pairs <= 4, "the reference holds 4 pairs cut 100 bases apart")
        let reference = Array(reference())
        let bundle = parent.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var first = ""
        var second = ""
        for index in 0..<pairs {
            let start = 30 + index * 100
            first += record("\(name)p\(index) 1:N:0:A", String(reference[start..<start + 60]))
            second += record("\(name)p\(index) 2:N:0:A", reverseComplement(String(reference[start + 140..<start + 200])))
        }
        let r1 = bundle.appendingPathComponent("s_R1.fastq")
        let r2 = bundle.appendingPathComponent("s_R2.fastq")
        try first.write(to: r1, atomically: true, encoding: .utf8)
        try second.write(to: r2, atomically: true, encoding: .utf8)
        return PairedRoot(root: bundle.standardizedFileURL, r1: r1.standardizedFileURL, r2: r2.standardizedFileURL)
    }

    private static func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return base
            }
        })
    }
}
