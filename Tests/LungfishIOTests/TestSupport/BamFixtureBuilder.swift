// BamFixtureBuilder.swift - Test helper to generate synthetic BAM files.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishIO

/// Test helper that generates a minimal BAM file from explicit SAM content,
/// using samtools to compress. Used by tests that need synthetic BAM data
/// with known read/duplicate patterns.
enum BamFixtureBuilder {

    struct Reference {
        let name: String
        let length: Int
    }

    struct Read {
        let qname: String
        let flag: Int
        let rname: String
        let pos: Int         // 1-based
        let mapq: Int
        let cigar: String
        let seq: String
        let qual: String
    }

    /// Creates an indexed, coordinate-sorted BAM at `outputURL` from the given references and reads.
    /// Requires samtools to be available.
    static func makeBAM(
        at outputURL: URL,
        references: [Reference],
        reads: [Read],
        samtoolsPath: String
    ) throws {
        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Build SAM text
        var sam = "@HD\tVN:1.6\tSO:coordinate\n"
        for ref in references {
            sam += "@SQ\tSN:\(ref.name)\tLN:\(ref.length)\n"
        }
        for read in reads {
            sam += "\(read.qname)\t\(read.flag)\t\(read.rname)\t\(read.pos)\t\(read.mapq)\t\(read.cigar)\t*\t0\t0\t\(read.seq)\t\(read.qual)\n"
        }

        // Write to intermediate SAM file, then convert + sort via samtools
        let samURL = outputURL.deletingPathExtension().appendingPathExtension("sam")
        try sam.write(to: samURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: samURL) }

        // samtools sort -o output.bam input.sam (coordinate sort by default)
        let sortProc = Process()
        sortProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        sortProc.arguments = ["sort", "-o", outputURL.path, samURL.path]
        let errPipe = Pipe()
        sortProc.standardOutput = FileHandle.nullDevice
        sortProc.standardError = errPipe
        try sortProc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        sortProc.waitUntilExit()
        guard sortProc.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "BamFixtureBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "samtools sort failed: \(stderr)"])
        }

        // Index
        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", outputURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        indexProc.standardError = FileHandle.nullDevice
        try indexProc.run()
        indexProc.waitUntilExit()
        guard indexProc.terminationStatus == 0 else {
            throw NSError(domain: "BamFixtureBuilder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "samtools index failed"])
        }
    }

    /// Convenience: returns the path to samtools if available, or nil if not.
    static func locateSamtools() -> String? {
        if let managed = SamtoolsLocator.locate() {
            return managed
        }

        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/samtools"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        for candidate in ["/opt/homebrew/bin/samtools", "/usr/local/bin/samtools", "/usr/bin/samtools"] {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
