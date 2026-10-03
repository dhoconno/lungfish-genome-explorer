// FASTQCLIMaterializer+FullMixed.swift - One file of every read a mixed bundle holds, by role
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQCLIMaterializer {

    /// Writes every read of a `fullMixed` bundle to `outputURL`: each R1 and
    /// R2 file pair interleaved with reformat.sh, then every merged file, then
    /// every unpaired file, each role in manifest order.
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
        outputURL: URL
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
            try await interleaveWithReformat(r1URL: r1URL, r2URL: r2URL, outputURL: interleavedURL)
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
}
