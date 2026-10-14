// DerivedAlignmentTrackFixture.swift - A bundle with a source and a derived alignment track, no tool needed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51. The Inspector's removal row and `lungfish-cli bam remove-track` remove a
// derived alignment track, which `bam filter` made, from a reference bundle. The removal reads no
// alignment record, so the fixture writes small files of known bytes in place of the BAM, its index
// and its statistics database, with the provenance sidecar `bam filter` leaves beside the BAM.

import Foundation
import LungfishCore

/// `<root>/Project.lungfish/Sample.lungfishref` with the source track `aln-source` and the derived
/// track `aln-derived` under `alignments/filtered/`.
public struct DerivedAlignmentTrackFixture: Sendable {
    public static let sourceTrackID = "aln-source"
    public static let derivedTrackID = "aln-derived"
    public static let derivedTrackName = "Sample 1 filtered"

    /// The derived track's BAM, index and statistics database, in the order the manifest names them.
    public static let derivedArtifactPaths = [
        "alignments/filtered/aln-derived.bam",
        "alignments/filtered/aln-derived.bam.bai",
        "alignments/filtered/aln-derived.stats.db",
    ]

    /// The provenance sidecar `bam filter` writes beside the derived BAM.
    public static let derivedSidecarPath = "alignments/filtered/aln-derived.bam.lungfish-provenance.json"

    /// The source track's files, which a removal never touches.
    public static let sourcePaths = ["alignments/source.bam", "alignments/source.bam.bai"]

    public let projectURL: URL
    public let bundleURL: URL

    /// Makes the project and its bundle in `root`. With `derivedBAMSize`, the derived BAM is a sparse
    /// file of that many bytes, which a removal takes long to hash, so a test can cancel it at work.
    public static func make(in root: URL, derivedBAMSize: UInt64? = nil) throws -> DerivedAlignmentTrackFixture {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("alignments/filtered", isDirectory: true),
            withIntermediateDirectories: true
        )
        let files: [(path: String, text: String)] = [
            (sourcePaths[0], "source bam bytes\n"),
            (sourcePaths[1], "source bai bytes\n"),
            (derivedArtifactPaths[0], "derived bam bytes\n"),
            (derivedArtifactPaths[1], "derived bai bytes\n"),
            (derivedArtifactPaths[2], "derived stats bytes\n"),
            (derivedSidecarPath, "{\"fixture\":\"the record bam filter wrote\"}\n"),
        ]
        for file in files {
            try Data(file.text.utf8).write(to: bundle.appendingPathComponent(file.path))
        }
        if let derivedBAMSize {
            let handle = try FileHandle(forWritingTo: bundle.appendingPathComponent(derivedArtifactPaths[0]))
            try handle.truncate(atOffset: derivedBAMSize)
            try handle.close()
        }
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Sample",
            identifier: "a51.derived-alignment-fixture",
            source: SourceInfo(organism: "Fixture organism", assembly: "Fixture assembly", database: "Fixture database"),
            genome: nil,
            alignments: [
                AlignmentTrackInfo(
                    id: sourceTrackID, name: "Sample 1", format: .bam,
                    sourcePath: sourcePaths[0], indexPath: sourcePaths[1]
                ),
                AlignmentTrackInfo(
                    id: derivedTrackID, name: derivedTrackName, format: .bam,
                    sourcePath: derivedArtifactPaths[0], indexPath: derivedArtifactPaths[1],
                    metadataDBPath: derivedArtifactPaths[2]
                ),
            ]
        )
        try manifest.save(to: bundle)
        return DerivedAlignmentTrackFixture(projectURL: project, bundleURL: bundle)
    }

    /// Puts the real BAM at `bam` and its `.bai` in place of both tracks' BAM and index, for a
    /// comparison that reads alignments with samtools, such as `OutputEquivalence` of a bundle.
    public func useAlignment(_ bam: URL) throws {
        let pairs = [
            (Self.sourcePaths[0], Self.sourcePaths[1]),
            (Self.derivedArtifactPaths[0], Self.derivedArtifactPaths[1]),
        ]
        for (bamPath, indexPath) in pairs {
            for (source, path) in [(bam, bamPath), (bam.appendingPathExtension("bai"), indexPath)] {
                let target = bundleURL.appendingPathComponent(path)
                try FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    /// Makes the derived statistics database a sparse file of `size` bytes whose first byte no text
    /// holds, so a removal takes long to hash it and a comparison reads it as binary.
    public func makeDerivedDatabaseSparse(size: UInt64) throws {
        let url = bundleURL.appendingPathComponent(Self.derivedArtifactPaths[2])
        try Data([0xFF]).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    /// The fixture of a bundle already in `root`, as a parity side's copy holds it.
    public static func existing(in root: URL) -> DerivedAlignmentTrackFixture {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        return DerivedAlignmentTrackFixture(
            projectURL: project,
            bundleURL: project.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        )
    }

    /// Every regular file under the bundle by its path relative to the bundle, sorted.
    public func relativeFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found.append(relativePath(of: url))
        }
        return found.sorted()
    }

    /// The bundle-relative path of `url`, which need not exist any more. A temporary folder may be
    /// spelled with or without its leading `/private`.
    public func relativePath(of url: URL) -> String {
        let root = Self.unprivate(bundleURL.standardizedFileURL.path) + "/"
        let path = Self.unprivate(url.standardizedFileURL.path)
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private static func unprivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
