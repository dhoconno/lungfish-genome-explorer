// STARPlanLauncherConformanceTests.swift - The three STAR batches of the Docker run (Phase 5.3 lane EX-PLAN-STAR, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// Not part of the default run, which skips it. `STARPlanTests` pins the plans' bytes on stand-in index records. This writes
/// the batches that `bash scripts/linux/launcher-tier.sh run` runs in the pinned image, on the index that `rnaseq index-plan`
/// and `rnaseq index-adopt` left for the small set of `STARIndexPlanLauncherConformanceTests`, so the real STAR 2.7.11b and
/// 2.7.3a and featureCounts read the staged index and the set's `derived/genes.gtf`. It runs when these name what the
/// earlier steps left, and `LUNGFISH_EX_STAR_FOLDER` is a folder that does not exist yet.
///
/// - `LUNGFISH_EX_STAR_ROOT`, the storage root that holds the set and the adopted index records
/// - `LUNGFISH_EX_STAR_EXECUTOR_MANIFEST`, the `manifest.json` that `linux_executor.py build` wrote beside the executor
/// - `LUNGFISH_EX_STAR_READS`, the folder of `staged.tsv`, the staged reads' path, bytes and SHA-256
/// - `LUNGFISH_EX_STAR_STAGING`, the staging folder that the index batches and these batches share
final class STARPlanLauncherConformanceTests: XCTestCase {
    private func variable(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Set \(name), and the other LUNGFISH_EX_STAR_ variables the file header names, to write the batches of the Docker run.")
        }
        return value
    }

    /// The tool manifest and image record of the head's `Resources/CHTCImage`, which `rnaseq index-plan` read too.
    private func imageFiles() throws -> (record: ExecutorPlanImageRecord, tools: ImageToolManifest, pin: PlanImageManifestPin) {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/CHTCImage", isDirectory: true)
        let bytes = try Data(contentsOf: resources.appendingPathComponent("image-manifest.json"))
        let record = try JSONDecoder().decode(
            ExecutorPlanImageRecord.self, from: Data(contentsOf: resources.appendingPathComponent("image.json")))
        let pin = PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        XCTAssertEqual(record.imageManifest, pin, "image.json pins this tool manifest")
        return (record, try ImageToolManifest.decode(bytes), pin)
    }

    /// The one sample, of the pair `stage.py reads` drew from the 13 genes' CDS and staged at the paths of `staged.tsv`.
    private func stagedPair(in reads: URL) throws -> SalmonPlanSample {
        let rows = try String(contentsOf: reads.appendingPathComponent("staged.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t").map(String.init) }
        let staged = try rows.map { row -> SalmonPlanStagedRead in
            SalmonPlanStagedRead(path: row[0], size: try XCTUnwrap(Int64(row[1])), sha256: row[2])
        }
        XCTAssertEqual(staged.count, 2)
        return SalmonPlan.stagedSample(name: "S1", pairs: [(staged[0], staged[1])], model: "NovaSeq 6000")
    }

    func testWritesTheThreeSTARBatchesThatTheLauncherTierRuns() async throws {
        let out = URL(fileURLWithPath: try variable("LUNGFISH_EX_STAR_FOLDER"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "name a new folder, so that no earlier batch is reused")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let storageRoot = URL(fileURLWithPath: try variable("LUNGFISH_EX_STAR_ROOT"), isDirectory: true)
        let manifestURL = URL(fileURLWithPath: try variable("LUNGFISH_EX_STAR_EXECUTOR_MANIFEST"))
        let staging = try variable("LUNGFISH_EX_STAR_STAGING")
        let sample = try stagedPair(in: URL(fileURLWithPath: try variable("LUNGFISH_EX_STAR_READS"), isDirectory: true))
        let executor = try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: Data(contentsOf: manifestURL))
        let image = try imageFiles()

        let sets = storageRoot.appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
        let setFolders = try FileManager.default.contentsOfDirectory(at: sets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ReferenceSetManifest.folderExtension }
        XCTAssertEqual(setFolders.count, 1, "the storage root holds the one set the index batches planned")
        let setFolder = try XCTUnwrap(setFolders.first)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let adopted = try FileManager.default.contentsOfDirectory(
            atPath: storageRoot.appendingPathComponent("rnaseq-index-records/\(manifest.id)").path)

        let runs: [(name: String, star: String, chain: STARPlanChain)] = [
            ("star-2711-genecounts", "2.7.11b", .geneCounts), ("star-2711-featurecounts", "2.7.11b", .featureCounts),
            ("star-273a-genecounts", "2.7.3a", .geneCounts),
        ]
        for run in runs {
            let pins = try STARPlanPins(
                executor: executor.sourceFile(besideManifestAt: manifestURL), executorBuild: executor.build,
                imageManifest: image.pin, toolManifest: image.tools, star: try XCTUnwrap(STARIndexVersion(rawValue: run.star)))
            let layout = ExecutorPlanStagingLayout(folder: staging, batch: run.name)
            let key = try XCTUnwrap(adopted.first { $0.hasPrefix("star-\(run.star)-") }, "no adopted index of STAR \(run.star)")
            let index = try ExecutorPlanStagedIndex.pin(
                setID: manifest.id, key: key, store: STARIndexRecordStore(storageRoot: storageRoot), star: pins.star, layout: layout)
            let made = try STARPlan.make(STARPlanRequest(
                setFolder: setFolder, sample: sample, pins: pins, chain: run.chain, index: index, trim: .trimGalore(polyG: false)))
            let figures = try STARPlanSubmit.figures(for: manifest, made: made, memoryMiB: 4096, cpus: 8, diskGiB: 5)
            let batch = try STARPlanSubmit.write(
                [(made, figures)], image: image.record, layout: layout, into: out.appendingPathComponent(run.name, isDirectory: true))
            let readFromStaging = batch.files.filter { $0.stagingPath.contains("/index/staged/") }
            XCTAssertEqual(readFromStaging.count, index.entries.count, "each index file is listed once")
            XCTAssertTrue(readFromStaging.allSatisfy { $0.source == nil }, "no index file is uploaded from the Mac")
            print("EX-PLAN-STAR batch: \(batch.folder.path) (\(key), \(run.chain.rawValue))")
        }
    }
}
