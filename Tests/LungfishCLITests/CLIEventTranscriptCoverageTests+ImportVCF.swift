// CLIEventTranscriptCoverageTests+ImportVCF.swift - The in-process captures of import vcf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI
import LungfishCore
import LungfishIO

/// `import vcf` attaches the sarscov2 fixture VCF to a reference bundle in process and runs no tool, so its
/// transcripts are captured in process (Phase 2.12 lane 12.07, A64), as the Import Center runs it: into a
/// manifest-only bundle of a scratch project with `--format json`. `failed` names a VCF that does not exist. They
/// live here because the main file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func importVCFCaptures() -> [Capture] {
        ["complete", "failed"].map { name in
            Capture(leaf: "import vcf", name: name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                let bundle = scratch.project.appendingPathComponent("Reference.lungfishref", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try BundleManifest(
                    name: "Reference",
                    identifier: "bundle.reference",
                    source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "Test")
                ).save(to: bundle)
                let input = scratch.root.appendingPathComponent(name == "complete" ? "calls.vcf" : "missing.vcf")
                if name == "complete" {
                    let fixture = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("Fixtures/sarscov2/test.vcf")
                    try FileManager.default.copyItem(at: fixture, to: input)
                }
                let command = try ImportCommand.VCFSubcommand.parse([input.path, "--output-dir", bundle.path, "--format", "json"])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
            }
        }
    }
}
