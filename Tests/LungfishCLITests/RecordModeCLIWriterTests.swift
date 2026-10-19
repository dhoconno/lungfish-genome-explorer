// RecordModeCLIWriterTests.swift - Records that lungfish-cli writes read 0644 under umask 022
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.23 M1 and M2 (RECORD-MODE, plan X10). Red at the base. DurableAtomicFileStore created the first
// record of a folder with S_IRUSR | S_IWUSR, so a record the CLI wrote read 0600 where the app's records read 0644
// (DurableReplace stages with 0o666 under the umask). One case for each CLI writer family.
//
// - A keyless ProvenanceWriter record, the first record of a folder, through `recordSingleStepRun`.
// - The genotype CLI, through `GenotypeExportProvenanceSupport.record`, the call every genotype subcommand makes.
// - `import bam`, the real subcommand in process on the sarscov2 BAM (RecordModeImportBAMConformanceTests, since
//   it needs the managed samtools).
// - TaxTriage on its CLI route reaches the same record route (`BuildDbCommand+TaxTriageCore.swift` writes its record
//   through `ProvenanceWriter().write`). A full TaxTriage run needs Nextflow, so its replay class carries the
//   harness's mode comparison instead of a case here.

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RecordModeCLIWriterTests: RecordModeTestCase {
    func testAKeylessProvenanceRecordReads0644() async throws {
        let folder = scratch.appendingPathComponent("Keyless", isDirectory: true)
        try await recordRun(into: folder)
        assertEveryFileReads0644(under: folder)
    }

    func testTheGenotypeCLIRecordReads0644() async throws {
        let bundle = scratch.appendingPathComponent("Calls.lungfishgenotype", isDirectory: true)
        let folder = scratch.appendingPathComponent("Genotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("calls.csv")
        try Data("sample,call\n".utf8).write(to: output)
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "lungfish genotype export",
            toolName: "lungfish genotype export",
            command: ["lungfish-cli", "genotype", "export"],
            bundleURL: bundle,
            outputURLs: [output],
            outputDirectory: folder,
            optionPaths: [:],
            runClock: ProvenanceRunClock()
        )
        assertEveryFileReads0644(under: folder)
    }
}

/// Runs the real `import bam` subcommand, so it needs the managed samtools and is named for it.
final class RecordModeImportBAMConformanceTests: RecordModeTestCase {
    func testImportBAMWritesNoFileNarrowerThan0644() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            try ToolAvailability.skipOrFail("Managed samtools is required: \(error)")
        }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let incoming = project.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        let bam = incoming.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: bam)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundle)

        var command = try ImportCommand.BAMSubcommand.parse([
            bam.path, "--output-dir", bundle.path, "--name", bam.lastPathComponent,
        ])
        try await command.run()

        assertEveryFileReads0644(under: project, except: ["Incoming/" + bam.lastPathComponent])
    }
}
