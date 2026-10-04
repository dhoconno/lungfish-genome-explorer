// FASTQDerivativeService+BBTools.swift - BBTools operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    // MARK: - BBTools Operations

    /// Builds environment variables required by BBTools shell scripts.
    ///
    /// Result is cached after first call since the managed environment path is stable.
    func bbToolsEnvironment() async -> [String: String] {
        if let cached = cachedBBToolsEnv {
            return cached
        }
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
        cachedBBToolsEnv = env
        return env
    }

    /// Runs bbmerge.sh to merge overlapping paired-end reads.
    ///
    /// Requires interleaved input. bbmerge emits merged reads plus a single
    /// interleaved unmerged stream, which we then split back into R1/R2 files.
    func runBBMerge(
        sourceFASTQ: URL,
        outputBundleURL: URL,
        strictness: FASTQMergeStrictness,
        minOverlap: Int,
        countDuplicateMergedReads: Bool = true,
        isInterleaved: Bool = true,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws -> ReadClassification {
        let mergedURL = outputBundleURL.appendingPathComponent("merged.fastq")
        let countedMergedURL = outputBundleURL.appendingPathComponent("merged.counted.fastq")
        let unmergedInterleavedURL = outputBundleURL.appendingPathComponent("unmerged.fastq")
        let unmergedR1URL = outputBundleURL.appendingPathComponent("unmerged_R1.fastq")
        let unmergedR2URL = outputBundleURL.appendingPathComponent("unmerged_R2.fastq")

        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedInterleavedURL.path)",
            "minoverlap=\(minOverlap)",
            // Stated, not guessed: bbmerge's own detection does not pair
            // identically named mates (SRA dumps), and on /1 /2 names it
            // pairs by position and drops the last read of an odd count.
            isInterleaved ? "interleaved=t" : "interleaved=f",
        ]

        if strictness == .strict {
            args.append("strict=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .bbmerge,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbmerge failed: \(result.stderr)")
        }

        if FileManager.default.fileExists(atPath: unmergedInterleavedURL.path) {
            try await deinterleaveFASTQ(
                source: unmergedInterleavedURL,
                outputR1: unmergedR1URL,
                outputR2: unmergedR2URL,
                provenanceCollector: provenanceCollector
            )
            try? FileManager.default.removeItem(at: unmergedInterleavedURL)
        }

        var mergedCount = 0
        if FileManager.default.fileExists(atPath: mergedURL.path) {
            if countDuplicateMergedReads {
                let summary = try await CountedFASTQMaterializer().materialize(
                    inputs: [mergedURL],
                    outputURL: countedMergedURL,
                    normalization: .uppercase
                )
                try? FileManager.default.removeItem(at: mergedURL)
                try FileManager.default.moveItem(at: countedMergedURL, to: mergedURL)
                mergedCount = summary.totalReadCount
            } else {
                mergedCount = try countFASTQReads(at: mergedURL)
            }
        }
        let r1Count =
            FileManager.default.fileExists(atPath: unmergedR1URL.path)
            ? try countFASTQReads(at: unmergedR1URL)
            : 0
        let r2Count =
            FileManager.default.fileExists(atPath: unmergedR2URL.path)
            ? try countFASTQReads(at: unmergedR2URL)
            : 0

        // Remove empty output files
        var files: [ReadClassification.FileEntry] = []
        if r1Count > 0 {
            files.append(.init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: r1Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR1URL)
        }
        if r2Count > 0 {
            files.append(.init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: r2Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR2URL)
        }
        if mergedCount > 0 {
            files.append(.init(filename: "merged.fastq", role: .merged, readCount: mergedCount))
        } else {
            try? FileManager.default.removeItem(at: mergedURL)
        }

        return ReadClassification(files: files)
    }

    /// Concatenates multiple FASTQ files into one output file.
    func concatenateFASTQFiles(_ inputFiles: [URL], to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputFiles {
            guard FileManager.default.fileExists(atPath: inputURL.path) else { continue }
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            defer { try? inputHandle.close() }

            // Stream in chunks to avoid loading entire files into memory
            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576) // 1 MB chunks
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }
    }

    /// Counts FASTQ reads in a file by counting lines and dividing by 4.
    func countFASTQReads(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineCount = 0
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return lineCount / 4
    }
}
