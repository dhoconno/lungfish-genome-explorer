// CLIEventTranscriptCoverageTests+ProjectCopyItem.swift - The in-process captures of project copy-item
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI

/// `project copy-item` copies files and runs no tool, so its transcripts are captured in process (Phase 2.12
/// lane 12.18). `complete` copies a reference bundle from `Source.lungfish` into the scratch project, as a
/// drop onto the sidebar of another project window does, and `failed` names an item that is not there, which
/// the leaf refuses with exit 3 before it writes anything. This lives here because the main file is past 800
/// lines.
extension CLIEventTranscriptCoverageTests {
    static func projectCopyItemCaptures() -> [Capture] {
        ["complete", "failed"].map { name in
            Capture(leaf: "project copy-item", name: name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                let source = scratch.root.appendingPathComponent("Source.lungfish", isDirectory: true)
                let item = name == "complete" ? "Reference Sequences/NC_045512.lungfishref" : "Reference Sequences/Missing.lungfishref"
                try scratch.write("Source.lungfish/Reference Sequences/NC_045512.lungfishref/sequence.fasta", ">NC_045512\nACGT\n")
                let command = try ProjectCopyItemSubcommand.parse([
                    item, "--source-project", source.path, "--project", scratch.project.path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }.standardOutput
            }
        }
    }
}
