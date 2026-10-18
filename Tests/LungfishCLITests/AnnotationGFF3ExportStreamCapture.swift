// AnnotationGFF3ExportStreamCapture.swift - Runs bundle export-gff3 in process on a small reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishCLI

/// The runs of `bundle export-gff3` (Phase 2.12 lane 12.39) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/bundle-export-gff3`. The command needs no tool.
/// `CLIEventTranscriptCoverageTests` runs them through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`.
enum AnnotationGFF3ExportStreamCapture {
    /// A reference bundle with one annotation database of one gene, as `CapturedSequenceExportTests` builds it.
    static func makeBundle(in folder: URL, name: String = "fixture") throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("annotations"), withIntermediateDirectories: true)
        let bed = folder.appendingPathComponent("\(name)-genes.bed")
        try "chr1\t10\t20\tgene-a\t0\t+\t10\t20\t0,0,0\t1\t10\t0\tgene\ttag=value\n"
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        try FileManager.default.removeItem(at: bed)
        try BundleManifest(
            name: "Annotation Export Fixture",
            identifier: "org.lungfish.annotation-export-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: nil,
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    static func cases() -> [ImportStreamCapture.Case] {
        func run(_ scratch: ImportStreamCapture.Scratch, bundle: URL) async throws -> ImportStreamCapture.Output {
            let command = try BundleExportGFF3Subcommand.parse([
                bundle.path, "-o", scratch.root.appendingPathComponent("fixture.gff3").path, "--format", "json",
            ])
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }
        return [
            ImportStreamCapture.Case(leaf: "bundle export-gff3", name: "complete") { scratch in
                try await run(scratch, bundle: try makeBundle(in: scratch.root))
            },
            // A folder with no manifest is refused before anything is written, with exit 3.
            ImportStreamCapture.Case(leaf: "bundle export-gff3", name: "failed") { scratch in
                try await run(scratch, bundle: scratch.root.appendingPathComponent("missing.lungfishref", isDirectory: true))
            },
        ]
    }
}
