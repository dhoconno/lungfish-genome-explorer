// BAMAdoptMappingTrackRecordTests.swift - Each adopted track keeps its own mapping record, and a failed adopt takes back only its own files
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

/// Phase 2.13 lane 13.16, items 1 and 4 of the BIO ruling on REC-RUN. Every adopted BAM lands in
/// `alignments/mapped/`, so a mapping record saved there under one shared name belonged to whichever track
/// was adopted last, and a failed adopt deleted it along with the BAM it had moved out of the mapping folder.
@Suite("BAMAdoptMappingTrackRecord")
struct BAMAdoptMappingTrackRecordTests {

    /// Item 1. The adopt saves the mapping folder's typed record as `<bam stem>.mapping-provenance.json`, and the
    /// adopt record's output, its `sourceMappingProvenancePath` and the stats key name that file.
    @Test("a second adopt keeps the first track's mapping record")
    func testASecondAdoptKeepsTheFirstTracksMappingRecord() async throws {
        let scene = try AdoptScene.make("adopt-second")
        defer { scene.cleanup() }
        let first = try scene.stageMappingFolder(named: "first")
        try AdoptableMappingRecord.write(into: first)
        try await scene.adopt(first, trackID: "first")
        let firstRecordURL = scene.mappedFolder.appendingPathComponent("first.mapping-provenance.json")
        let firstRecord = try Data(contentsOf: firstRecordURL)

        let second = try scene.stageMappingFolder(named: "second")
        try AdoptableMappingRecord.write(into: second, planHome: .recordLevel(AdoptableMappingRecord.mixedSamplePlan))
        try await scene.adopt(second, trackID: "second")

        #expect(try Data(contentsOf: firstRecordURL) == firstRecord, "the first track's mapping record is as the first adopt saved it")
        let secondRecordURL = scene.mappedFolder.appendingPathComponent("second.mapping-provenance.json")
        #expect(try Data(contentsOf: secondRecordURL) != firstRecord, "the second track has a record of its own")
        #expect(
            !FileManager.default.fileExists(atPath: scene.mappedFolder.appendingPathComponent("mapping-provenance.json").path),
            "no adopt writes the shared name"
        )

        let adoptRecordURL = scene.mappedFolder.appendingPathComponent("first.adopt-mapping-provenance.json")
        let run = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: adoptRecordURL)).legacyWorkflowRun()
        #expect(run.parameters["sourceMappingProvenancePath"]?.stringValue == "alignments/mapped/first.mapping-provenance.json")
        let output = try #require(run.allOutputFiles.first { $0.path.hasSuffix("/first.mapping-provenance.json") })
        #expect(output.sha256 == ProvenanceRecorder.sha256(of: firstRecordURL), "the adopt record's digest is the saved record's")
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: scene.mappedFolder.appendingPathComponent("first.stats.db"))
        #expect(metadataDB.getFileInfo("source_mapping_provenance_path") == "alignments/mapped/first.mapping-provenance.json")
    }

    /// Item 4. The rollback removes the files the run made, from a list it fills as it makes each one, moves the
    /// BAM and index back to the mapping folder they came from, and puts back the manifest's bytes.
    @Test("a failed adopt leaves the earlier track and returns the BAM")
    func testAFailedAdoptLeavesTheEarlierTrackAndReturnsTheBAM() async throws {
        let scene = try AdoptScene.make("adopt-failed")
        defer { scene.cleanup() }
        let first = try scene.stageMappingFolder(named: "first")
        try AdoptableMappingRecord.write(into: first)
        try await scene.adopt(first, trackID: "first")
        let filesBefore = scene.bundleFiles()
        let manifestBefore = try Data(contentsOf: scene.manifestURL)

        let second = try scene.stageMappingFolder(named: "second")
        try AdoptableMappingRecord.write(into: second, planHome: .recordLevel(AdoptableMappingRecord.mixedSamplePlan))
        // A folder where the second adopt record goes fails its write, after the attach moved the BAM and the
        // adopt saved the track's mapping record.
        let blocker = scene.mappedFolder.appendingPathComponent("second.adopt-mapping-provenance.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            try await scene.adopt(second, trackID: "second")
        }

        #expect(scene.bundleFiles() == filesBefore, "the earlier track's files are byte-identical and the run left none of its own")
        #expect(try Data(contentsOf: scene.manifestURL) == manifestBefore, "manifest.json holds its original bytes")
        for name in ["sorted.bam", "sorted.bam.bai"] {
            #expect(
                FileManager.default.fileExists(atPath: second.appendingPathComponent(name).path),
                "the mapping folder holds its \(name) again"
            )
        }
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "the rollback leaves what the run did not make"
        )
    }

    /// Review Fix 1. The attach itself fails, here in its metadata step on a BAM samtools cannot read, so the adopt's
    /// rollback never runs. The attach gives the BAM and index back to the mapping folder and the bundle keeps none
    /// of the run's files.
    @Test("an adopt whose attach fails returns the BAM")
    func testAnAdoptWhoseAttachFailsReturnsTheBAM() async throws {
        let scene = try AdoptScene.make("adopt-attach-failed")
        defer { scene.cleanup() }
        let folder = try scene.stageMappingFolder(named: "unreadable")
        let bam = folder.appendingPathComponent("sorted.bam")
        let index = folder.appendingPathComponent("sorted.bam.bai")
        try Data("not a BAM".utf8).write(to: bam)
        try Data("not an index".utf8).write(to: index)
        try AdoptableMappingRecord.write(into: folder)
        let filesBefore = scene.bundleFiles()
        let manifestBefore = try Data(contentsOf: scene.manifestURL)

        await #expect(throws: (any Error).self) {
            try await scene.adopt(folder, trackID: "unreadable")
        }

        #expect((try? Data(contentsOf: bam)) == Data("not a BAM".utf8), "the mapping folder holds its BAM again with its bytes")
        #expect((try? Data(contentsOf: index)) == Data("not an index".utf8), "the mapping folder holds its index again with its bytes")
        #expect(scene.bundleFiles() == filesBefore, "the bundle keeps none of the run's files")
        #expect(try Data(contentsOf: scene.manifestURL) == manifestBefore, "manifest.json holds its original bytes")
    }
}

/// A bundle with one alignment track, and mapping folders to adopt into it.
private struct AdoptScene {
    let scratch: URL
    let fixture: BundleAlignmentFixture

    var bundleURL: URL { fixture.bundleURL }
    var manifestURL: URL { bundleURL.appendingPathComponent(BundleManifest.filename) }
    var mappedFolder: URL { bundleURL.appendingPathComponent("alignments/mapped", isDirectory: true) }

    static func make(_ prefix: String) throws -> AdoptScene {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: scratch)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: scratch,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )
        return AdoptScene(scratch: scratch, fixture: fixture)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A mapping folder holding a BAM and its index, which an adopt moves into the bundle.
    func stageMappingFolder(named name: String) throws -> URL {
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.sourceBAMURL, to: folder.appendingPathComponent("sorted.bam"))
        try FileManager.default.copyItem(at: fixture.sourceIndexURL, to: folder.appendingPathComponent("sorted.bam.bai"))
        return folder
    }

    func adopt(_ mappingDir: URL, trackID: String) async throws {
        let command = try BAMCommand.AdoptMappingSubcommand.parse([
            "--bundle", bundleURL.path,
            "--mapping-result", mappingDir.path,
            "--name", trackID,
            "--track-id", trackID,
            "--quiet",
        ])
        try await command.run()
    }

    /// Every regular file under the bundle, by its path from the bundle, with its bytes.
    func bundleFiles() -> [String: Data] {
        let prefix = bundleURL.standardizedFileURL.path + "/"
        var result: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return result
    }
}
