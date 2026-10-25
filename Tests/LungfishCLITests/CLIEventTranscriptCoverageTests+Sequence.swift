// CLIEventTranscriptCoverageTests+Sequence.swift - The in-process captures of the sequence edit leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI
import LungfishIO

/// `sequence add-annotation` and `sequence attach-track` run no tool, so their transcripts are
/// captured in process on a 16-base reference bundle (2.10 A42). They live here because the main
/// file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func sequenceCaptures() -> [Capture] {
        [
            Capture(leaf: "sequence add-annotation", name: "complete") { scratch in
                let bundle = try SequenceEditFixture.referenceBundle(in: scratch.root)
                let command = try SequenceCommand.AddAnnotation.parse([
                    bundle.path, "--chromosome", "chr1", "--start", "2", "--end", "9",
                    "--name", "selection-feature", "--type", "gene", "--strand", "+", "--format", "json",
                ])
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
            Capture(leaf: "sequence attach-track", name: "complete") { scratch in
                let bundle = try SequenceEditFixture.referenceBundle(in: scratch.root)
                let bed = try SequenceEditFixture.bedFile(in: scratch.root)
                let command = try SequenceCommand.AttachTrack.parse([
                    bundle.path, bed.path, "--track-id", "primers", "--format", "json",
                ])
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
        ]
    }
}

/// A reference bundle with one 16-base sequence `chr1`, and a BED file of two features on it, for
/// the sequence edit leaves' tests.
enum SequenceEditFixture {
    static func referenceBundle(in folder: URL, named name: String = "M1") throws -> URL {
        let bundleURL = folder.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGTACGTACGTACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t16\t6\t16\t17\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        // A fixed date, so two bundles made a second apart have the same manifest bytes and an app-against-CLI test
        // that compares their input digests does not depend on the clock.
        let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)
        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.sequence-edit",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 16,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 16, offset: 6, lineBases: 16, lineWidth: 17)]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    static func bedFile(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("primers.bed")
        try "chr1\t2\t9\tprimer-left\t0\t+\nchr1\t10\t15\tprimer-right\t0\t-\n".write(
            to: url, atomically: true, encoding: .utf8
        )
        return url
    }
}
