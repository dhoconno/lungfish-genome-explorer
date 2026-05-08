// BAMAdoptMappingIntegrationTests.swift — Integration test for `lungfish bam adopt-mapping`.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@Suite("BAMAdoptMappingIntegration")
struct BAMAdoptMappingIntegrationTests {

    @Test("adopts mapping result into the bundle as a new alignment track")
    func adoptsMapping() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-mapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Build a real bundle whose only manifest entry is a placeholder alignment
        //    track. `BundleAlignmentFixture` writes a samtools-built BAM next to the
        //    manifest so we have a faithful starting point — but our subcommand only
        //    needs the manifest to load, not the placeholder track itself.
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: scratch)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: scratch,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )

        // 2. Stage a fresh "mapping result" directory by copying the fixture BAM/BAI
        //    into sorted.bam / sorted.bam.bai. `PreparedAlignmentAttachmentService`
        //    *moves* the staged artifacts into the bundle, so we copy first to keep
        //    the fixture intact for any later assertions.
        let mappingDir = scratch.appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDir, withIntermediateDirectories: true)
        let stagedBAM = mappingDir.appendingPathComponent("sorted.bam")
        let stagedBAI = mappingDir.appendingPathComponent("sorted.bam.bai")
        try FileManager.default.copyItem(at: fixture.sourceBAMURL, to: stagedBAM)
        try FileManager.default.copyItem(at: fixture.sourceIndexURL, to: stagedBAI)
        try "{}".write(
            to: mappingDir.appendingPathComponent("mapping-provenance.json"),
            atomically: true,
            encoding: .utf8
        )

        // 3. Run the new subcommand programmatically.
        var cmd = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2 mapping"
        ])
        try await cmd.run()

        // 4. Assert the manifest gained a new alignment track.
        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        let adopted = manifest.alignments.first(where: { $0.id != fixture.sourceTrackID })
        #expect(adopted != nil)
        #expect(adopted?.name == "minimap2 mapping")
        #expect(adopted?.sourcePath.hasPrefix("alignments/mapped/") == true)
    }
}
