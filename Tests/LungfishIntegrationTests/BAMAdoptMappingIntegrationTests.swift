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
        let cmd = try BAMCommand.AdoptMappingSubcommand.parse([
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

        let adoptedTrack = try #require(adopted)
        let adoptedBAMURL = fixture.bundleURL.appendingPathComponent(adoptedTrack.sourcePath)
        let adoptProvenanceURL = adoptedBAMURL
            .deletingPathExtension()
            .appendingPathExtension("adopt-mapping-provenance.json")
        let rehydratedMappingProvenanceURL = adoptedBAMURL
            .deletingLastPathComponent()
            .appendingPathComponent("mapping-provenance.json")
        #expect(FileManager.default.fileExists(atPath: adoptProvenanceURL.path))
        #expect(FileManager.default.fileExists(atPath: rehydratedMappingProvenanceURL.path))

        let provenanceText = try String(contentsOf: adoptProvenanceURL, encoding: .utf8)
        #expect(provenanceText.contains("lungfish bam adopt-mapping"))
        #expect(provenanceText.contains("mapping-provenance.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenanceRun = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: adoptProvenanceURL))
        #expect(provenanceRun.allOutputFiles.contains { $0.path == adoptedBAMURL.path })

        let metadataDBPath = try #require(adoptedTrack.metadataDBPath)
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(
            at: fixture.bundleURL.appendingPathComponent(metadataDBPath)
        )
        #expect(metadataDB.getFileInfo("adopt_mapping_provenance_path") == "alignments/mapped/\(adoptedTrack.id).adopt-mapping-provenance.json")
        #expect(metadataDB.provenanceHistory().map(\.subcommand).contains("bam adopt-mapping"))
    }

    @Test("adopts BAM and BAI paths declared by mapping-result.json")
    func adoptsMappingResultSidecarPaths() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-mapping-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: scratch)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: scratch,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )

        let mappingDir = scratch.appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: mappingDir, withIntermediateDirectories: true)
        let stagedBAM = mappingDir.appendingPathComponent("SRR36291587.sorted.bam")
        let stagedBAI = mappingDir.appendingPathComponent("SRR36291587.sorted.bam.bai")
        try FileManager.default.copyItem(at: fixture.sourceBAMURL, to: stagedBAM)
        try FileManager.default.copyItem(at: fixture.sourceIndexURL, to: stagedBAI)
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: stagedBAM,
            baiURL: stagedBAI,
            totalReads: 10,
            mappedReads: 10,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        ).save(to: mappingDir)
        try "{}".write(
            to: mappingDir.appendingPathComponent("mapping-provenance.json"),
            atomically: true,
            encoding: .utf8
        )

        let cmd = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2 mapping"
        ])
        try await cmd.run()

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        let adoptedTrack = try #require(manifest.alignments.first(where: { $0.id != fixture.sourceTrackID }))
        let adoptedBAMURL = fixture.bundleURL.appendingPathComponent(adoptedTrack.sourcePath)
        let adoptProvenanceURL = adoptedBAMURL
            .deletingPathExtension()
            .appendingPathExtension("adopt-mapping-provenance.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenanceRun = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: adoptProvenanceURL))

        #expect(provenanceRun.primaryInputFiles.contains { $0.path == stagedBAM.path })
        #expect(provenanceRun.primaryInputFiles.contains { $0.path == stagedBAI.path })
        #expect(provenanceRun.primaryInputFiles.contains {
            $0.path == mappingDir.appendingPathComponent("mapping-result.json").path
                && $0.sha256 != nil
                && $0.sizeBytes != nil
        })
        #expect(provenanceRun.allOutputFiles.contains { $0.path == adoptedBAMURL.path })
    }
}
