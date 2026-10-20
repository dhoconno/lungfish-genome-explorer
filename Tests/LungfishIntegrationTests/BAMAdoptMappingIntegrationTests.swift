// BAMAdoptMappingIntegrationTests.swift — Integration test for `lungfish bam adopt-mapping`.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
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
        try AdoptableMappingRecord.write(into: mappingDir)

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
            .deletingPathExtension()
            .appendingPathExtension("mapping-provenance.json")
        #expect(FileManager.default.fileExists(atPath: adoptProvenanceURL.path))
        #expect(FileManager.default.fileExists(atPath: rehydratedMappingProvenanceURL.path))

        let provenanceText = try String(contentsOf: adoptProvenanceURL, encoding: .utf8)
        #expect(provenanceText.contains("lungfish bam adopt-mapping"))
        #expect(provenanceText.contains("mapping-provenance.json"))
        let provenanceRun = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: adoptProvenanceURL)).legacyWorkflowRun()
        #expect(provenanceRun.allOutputFiles.contains { $0.path == adoptedBAMURL.path })
        #expect(try BareRunWriterParity.strictFindings(sidecar: adoptProvenanceURL) == [])

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
        try AdoptableMappingRecord.write(into: mappingDir)

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
        let provenanceRun = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: adoptProvenanceURL)).legacyWorkflowRun()

        #expect(provenanceRun.primaryInputFiles.contains { $0.path == stagedBAM.path })
        #expect(provenanceRun.primaryInputFiles.contains { $0.path == stagedBAI.path })
        #expect(provenanceRun.primaryInputFiles.contains {
            $0.path == mappingDir.appendingPathComponent("mapping-result.json").path
                && $0.sha256 != nil
                && $0.sizeBytes != nil
        })
        #expect(provenanceRun.allOutputFiles.contains { $0.path == adoptedBAMURL.path })
    }

    /// Phase 2.4, lane W2B: the record keeps the facts it had when it was a bare run. The run sits in a
    /// temporary `.lungfish` project, and the facts are in Tests/Fixtures/provenance-writer-parity.
    @Test("adopt-mapping keeps the facts of its provenance record")
    func adoptMappingProvenanceFacts() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let toolsFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-mapping-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: toolsFolder) }

        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: toolsFolder)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: project.root,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )
        let mappingDir = try project.folder("Analyses/mapping")
        try FileManager.default.copyItem(at: fixture.sourceBAMURL, to: mappingDir.appendingPathComponent("sorted.bam"))
        try FileManager.default.copyItem(at: fixture.sourceIndexURL, to: mappingDir.appendingPathComponent("sorted.bam.bai"))
        try AdoptableMappingRecord.write(into: mappingDir)

        let command = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", "minimap2 mapping",
            "--track-id", "adopted-mapping",
            "--quiet",
        ])
        try await command.run()

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        let adopted = try #require(manifest.alignments.first { $0.id == "adopted-mapping" })
        let sidecar = fixture.bundleURL
            .appendingPathComponent(adopted.sourcePath)
            .deletingPathExtension()
            .appendingPathExtension("adopt-mapping-provenance.json")
        let version = LungfishCLI.configuration.version
        let scenario = BareRunWriterParity.Scenarios.bamAdoptMapping
        let problems = try BareRunWriterParity.problemsAfterConversion(
            of: sidecar,
            in: project,
            scenario: scenario,
            replacing: [
                .literal("lungfish-cli \(version)", as: "lungfish-cli <cli-version>"),
                .version(version, as: "<cli-version>"),
                // BundleAlignmentFixture names its bundle with a fresh UUID.
                .regularExpression(#"BundleAlignmentFixture-[0-9A-Fa-f-]{36}"#, as: "BundleAlignmentFixture-<UUID>"),
            ]
        )
        #expect(problems.isEmpty, "bam-adopt-mapping changed: \(problems)")
        let findings = try BareRunWriterParity.strictFindings(sidecar: sidecar)
        #expect(findings.isEmpty, "bam-adopt-mapping record: \(findings)")
    }

    // MARK: What an adopted bundle keeps of the run (2.10 A36, 2.8 P5)

    /// A real typed record is saved again for the bundle and is all the bundle keeps of the run. The mapping
    /// folder's canonical record stays behind (2.8 P5), and so does every other file of the folder.
    @Test("adopting a real typed record keeps it once, saved again for the bundle")
    func adoptsRealTypedRecordAndKeepsOnlyIt() async throws {
        let scratch = try Self.makeScratch("adopt-real-record")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try Self.makeScene(in: scratch)
        let mappingDir = try scene.stageMappingFolder()
        try AdoptableMappingRecord.write(into: mappingDir)
        let source = try #require(MappingProvenance.load(from: mappingDir), "the golden record decodes")
        #expect(source.viewerBundlePath == nil, "the run had no viewer bundle yet")
        let canonicalURL = try source.saveCanonicalEnvelope(to: mappingDir)
        let filesBefore = Self.files(under: scene.bundleURL)

        try await scene.adopt(mappingDir, name: "real record", trackID: "real-record")

        let filesAfter = Self.files(under: scene.bundleURL)
        #expect(filesBefore.subtracting(filesAfter).isEmpty, "the bundle lost no file")
        #expect(
            filesAfter.subtracting(filesBefore) == [
                "alignments/mapped/real-record.bam",
                "alignments/mapped/real-record.bam.bai",
                "alignments/mapped/real-record.stats.db",
                "alignments/mapped/real-record.adopt-mapping-provenance.json",
                "alignments/mapped/real-record.mapping-provenance.json",
            ],
            "the bundle gained the track, the adopt record and one typed record"
        )
        #expect(
            !filesAfter.contains { ($0 as NSString).lastPathComponent == canonicalURL.lastPathComponent },
            "the mapping folder's canonical record \(canonicalURL.lastPathComponent) is not carried into the bundle"
        )
        let kept = try #require(MappingProvenance.load(fromFile: scene.keptRecordFolder.appendingPathComponent("real-record.mapping-provenance.json")), "the kept record decodes")
        #expect(
            kept.viewerBundlePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == scene.bundleURL.standardizedFileURL.path,
            "the kept record is rooted at the bundle"
        )
        #expect(
            kept.withViewerBundleURL(nil) == source.withViewerBundleURL(nil),
            "the kept record holds everything the run wrote"
        )
    }

    /// A released build recorded the plan of a mixed sample on the mapper step, and the typed record had no
    /// plan of its own. Adoption keeps that record as it was, and the one reader finds the same plan in the
    /// same place before and after.
    @Test("adopting a released mixed-sample record keeps its plan where the build wrote it")
    func adoptsReleasedMixedSampleRecord() async throws {
        let plan = AdoptableMappingRecord.mixedSamplePlan
        let (before, after) = try await adoptedPlan(of: .mapperStep(plan), trackID: "released-mixed")
        guard case .stepResolvedOptions = before.place else {
            Issue.record("the released record keeps its plan on the mapper step, not \(before.place)")
            return
        }
        #expect(before.fields == plan)
        #expect(after == before, "the plan reads the same from the adopted bundle")
    }

    /// A build since 2.7 keeps the plan of a mixed sample once, at the typed record's own level, which the one
    /// reader finds in the resolved defaults (2.7 R, E13).
    @Test("adopting a record that holds its plan at its own level keeps it there")
    func adoptsRecordWithItsPlanAtItsOwnLevel() async throws {
        let plan = AdoptableMappingRecord.mixedSamplePlan
        let (before, after) = try await adoptedPlan(of: .recordLevel(plan), trackID: "record-level")
        #expect(before.place == .resolvedDefaults)
        #expect(before.fields == plan)
        #expect(after == before, "the plan reads the same from the adopted bundle")
    }

    // MARK: A record the command cannot decode (2.10 A36)

    /// The attach moves the BAM out of the mapping folder, so a record the command refuses has to be refused
    /// before it, or the refusal would leave the folder without its BAM. Nothing else changes either.
    @Test(
        "refuses a mapping-provenance.json it cannot decode and changes nothing",
        arguments: ["{}", "[]", "not json at all"]
    )
    func refusesUndecodableMappingRecord(content: String) async throws {
        let scratch = try Self.makeScratch("adopt-refused")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try Self.makeScene(in: scratch)
        let mappingDir = try scene.stageMappingFolder()
        let recordURL = mappingDir.appendingPathComponent(MappingProvenance.filename)
        try content.write(to: recordURL, atomically: true, encoding: .utf8)
        let manifestBefore = try Data(contentsOf: scene.manifestURL)
        let filesBefore = Self.files(under: scene.bundleURL)

        await Self.expectRefusal(naming: recordURL) {
            try await scene.adopt(mappingDir, name: "refused", trackID: "refused")
        }

        #expect(try Data(contentsOf: scene.manifestURL) == manifestBefore, "the manifest is as it was")
        #expect(
            try BundleManifest.load(from: scene.bundleURL).alignments.map(\.id) == [scene.fixture.sourceTrackID],
            "the bundle gained no track"
        )
        #expect(Self.files(under: scene.bundleURL) == filesBefore, "the bundle gained no file")
        for name in ["sorted.bam", "sorted.bam.bai"] {
            #expect(
                FileManager.default.fileExists(atPath: mappingDir.appendingPathComponent(name).path),
                "the mapping folder keeps its \(name)"
            )
        }
        #expect(try String(contentsOf: recordURL, encoding: .utf8) == content, "the record is left as it was")
    }

    /// The typed record of every adopted track sits in one folder of the bundle, so a refusal that cleaned up
    /// after itself there would take the record of the track before it.
    @Test("a refused adoption leaves the track and the record an earlier adoption wrote")
    func refusalKeepsEarlierAdoption() async throws {
        let scratch = try Self.makeScratch("adopt-refused-later")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try Self.makeScene(in: scratch)
        let first = try scene.stageMappingFolder(named: "first")
        try AdoptableMappingRecord.write(into: first)
        try await scene.adopt(first, name: "first", trackID: "first")
        let keptURL = scene.keptRecordFolder.appendingPathComponent("first.mapping-provenance.json")
        let keptBefore = try Data(contentsOf: keptURL)
        let manifestBefore = try Data(contentsOf: scene.manifestURL)
        let filesBefore = Self.files(under: scene.bundleURL)

        let second = try scene.stageMappingFolder(named: "second")
        let brokenURL = second.appendingPathComponent(MappingProvenance.filename)
        try "{}".write(to: brokenURL, atomically: true, encoding: .utf8)
        await Self.expectRefusal(naming: brokenURL) {
            try await scene.adopt(second, name: "second", trackID: "second")
        }

        #expect(try Data(contentsOf: keptURL) == keptBefore, "the record of the first adoption is as it was")
        #expect(try Data(contentsOf: scene.manifestURL) == manifestBefore, "the manifest is as it was")
        #expect(Self.files(under: scene.bundleURL) == filesBefore, "the bundle gained and lost no file")
    }

    /// The command refuses with a `ValidationError` whose message holds the path of the record.
    private static func expectRefusal(naming recordURL: URL, from operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("the command adopted a mapping record it cannot decode")
        } catch let error as ValidationError {
            #expect(error.message.contains(recordURL.path), "the refusal names \(recordURL.path), not \(error.message)")
        } catch {
            Issue.record("expected a ValidationError that names \(recordURL.path), got \(error)")
        }
    }

    // MARK: Helpers

    /// The plan the reader of provenance records finds in the typed record of the mapping folder, and in the
    /// one the adopted bundle holds.
    private func adoptedPlan(
        of planHome: AdoptableMappingRecord.PlanHome,
        trackID: String
    ) async throws -> (before: RecordedReadSetPlan, after: RecordedReadSetPlan) {
        let scratch = try Self.makeScratch("adopt-plan-\(trackID)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try Self.makeScene(in: scratch)
        let mappingDir = try scene.stageMappingFolder()
        let sourceURL = try AdoptableMappingRecord.write(into: mappingDir, planHome: planHome)
        let before = try #require(Self.recordedPlan(in: sourceURL), "the reader finds the plan in the mapping folder")

        try await scene.adopt(mappingDir, name: trackID, trackID: trackID)

        let keptURL = scene.keptRecordFolder.appendingPathComponent("\(trackID).mapping-provenance.json")
        let after = try #require(Self.recordedPlan(in: keptURL), "the reader finds the plan in the bundle")
        return (before, after)
    }

    private static func recordedPlan(in recordURL: URL) -> RecordedReadSetPlan? {
        ProvenanceRecorder.findProvenanceReading(for: recordURL)?.reading.envelope.readSetPlan
    }

    private static func makeScratch(_ prefix: String) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private static func makeScene(in scratch: URL) throws -> Scene {
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: scratch)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: scratch,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )
        return Scene(scratch: scratch, fixture: fixture)
    }

    /// Every regular file under `root`, by its path from `root`.
    private static func files(under root: URL) -> Set<String> {
        let prefix = root.standardizedFileURL.path + "/"
        var result = Set<String>()
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return result
    }

    /// A bundle with one alignment track, and a folder for each mapping result to adopt into it.
    private struct Scene {
        let scratch: URL
        let fixture: BundleAlignmentFixture

        var bundleURL: URL { fixture.bundleURL }
        var manifestURL: URL { bundleURL.appendingPathComponent(BundleManifest.filename) }
        /// Where the bundle keeps a typed record that an adoption saved.
        var keptRecordFolder: URL { bundleURL.appendingPathComponent("alignments/mapped", isDirectory: true) }

        /// A mapping folder holding a BAM and its index, which an adoption moves into the bundle.
        func stageMappingFolder(named name: String = "mapping") throws -> URL {
            let folder = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.sourceBAMURL, to: folder.appendingPathComponent("sorted.bam"))
            try FileManager.default.copyItem(at: fixture.sourceIndexURL, to: folder.appendingPathComponent("sorted.bam.bai"))
            return folder
        }

        func adopt(_ mappingDir: URL, name: String, trackID: String) async throws {
            let command = try BAMCommand.AdoptMappingSubcommand.parse([
                "--bundle", bundleURL.path,
                "--mapping-result", mappingDir.path,
                "--name", name,
                "--track-id", trackID,
                "--quiet",
            ])
            try await command.run()
        }
    }
}
