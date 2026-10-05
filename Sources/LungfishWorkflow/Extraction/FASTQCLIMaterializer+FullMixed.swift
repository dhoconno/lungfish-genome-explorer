// FASTQCLIMaterializer+FullMixed.swift - One file of every read a mixed bundle holds, by role
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let mateCheckLogger = Logger(subsystem: LogSubsystem.workflow, category: "FASTQCLIMaterializer")

extension FASTQCLIMaterializer {

    /// Writes every read of a `fullMixed` bundle to `outputURL`: each R1 and
    /// R2 file pair interleaved with mate names checked
    /// (``interleaveMates(r1URL:r2URL:outputURL:progress:)``), then every merged
    /// file, then every unpaired file, each role in manifest order.
    ///
    /// Every file the manifest lists must exist, and the R1 and R2 files must
    /// come in equal numbers, or the call throws ``FASTQCLIMaterializerError/roleFileMissing(_:)``.
    /// The materializer used to read the first file of each role, skip a
    /// missing merged or unpaired file, and drop the R1 reads when no R2 was
    /// listed, so a bundle came back shorter without a word (D3, Phase 1.5
    /// lane A7).
    func materializeFullMixed(
        classification: ReadClassification,
        bundleURL: URL,
        tempDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        func memberURLs(_ role: ReadClassification.FileRole) throws -> [URL] {
            try classification.files.filter { $0.role == role }.map { entry in
                let url = try payloadMemberURL(
                    entry.filename,
                    in: bundleURL,
                    field: "readClassification.files[].filename"
                )
                guard fm.fileExists(atPath: url.path) else {
                    throw FASTQCLIMaterializerError.roleFileMissing(
                        "\(entry.filename) (\(entry.role.rawValue)) is listed but does not exist"
                    )
                }
                return url
            }
        }

        let r1URLs = try memberURLs(.pairedR1)
        let r2URLs = try memberURLs(.pairedR2)
        guard r1URLs.count == r2URLs.count else {
            throw FASTQCLIMaterializerError.roleFileMissing(
                "\(r1URLs.count) paired R1 file(s) are listed with \(r2URLs.count) paired R2 file(s), so a mate file has no partner"
            )
        }
        let singleURLs = try memberURLs(.merged) + memberURLs(.unpaired)

        var interleavedURLs: [URL] = []
        defer {
            for url in interleavedURLs { try? fm.removeItem(at: url) }
        }
        for (r1URL, r2URL) in zip(r1URLs, r2URLs) {
            let interleavedURL = tempDirectory
                .appendingPathComponent("interleaved-\(UUID().uuidString).fastq")
            interleavedURLs.append(interleavedURL)
            try interleaveMates(r1URL: r1URL, r2URL: r2URL, outputURL: interleavedURL, progress: progress)
        }

        let sources = interleavedURLs + singleURLs
        guard !sources.isEmpty else {
            throw FASTQCLIMaterializerError.sourceFASTQMissing
        }
        if sources.count == 1 {
            try fm.copyItem(at: sources[0], to: outputURL)
        } else {
            try concatenateFiles(sources, to: outputURL)
        }
    }

    /// Writes the records of `r1URL` and `r2URL` alternately to `outputURL`,
    /// each R1 record followed by its R2 mate, paired by position as
    /// reformat.sh paired them (``FASTQPairInterleaver/interleaveRecordedPair(r1:r2:to:)``).
    ///
    /// Names that carry a mate number (`/1` `/2`, `.1` `.2`, `_1` `_2` or a
    /// Casava comment) must be mates, and the files must hold equal numbers
    /// of records, or the call throws ``FASTQPairInterleaver/InterleaveError``.
    /// reformat.sh never checked names, so an R2 file out of step with its
    /// R1 gave mis-paired reads without a word (Phase 1.5 lane A7, Lead A
    /// review R2). Names that carry no mate number are paired by position
    /// with a warning, so a legacy bundle whose mates are named that way
    /// materializes as it did before (final review A, N2). For files in step
    /// the bytes are the ones reformat.sh wrote.
    func interleaveMates(
        r1URL: URL,
        r2URL: URL,
        outputURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw FASTQCLIMaterializerError.toolFailed("interleave", "cannot create \(outputURL.path)")
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let written: FASTQPairInterleaver.RecordedPairCounts
        do {
            written = try FASTQPairInterleaver.interleaveRecordedPair(r1: r1URL, r2: r2URL, to: handle)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        if let first = written.firstPairedByPosition, first.count == 2 {
            let warning = "Warning: \(written.pairedByPosition) of the \(written.counts.r1Records) record pairs of "
                + "\(r1URL.lastPathComponent) and \(r2URL.lastPathComponent) carry no mate number in their names, "
                + "the first being '\(first[0])' and '\(first[1])', so they were paired by position."
            mateCheckLogger.warning("\(warning, privacy: .public)")
            progress?(warning)
        }
    }
}
