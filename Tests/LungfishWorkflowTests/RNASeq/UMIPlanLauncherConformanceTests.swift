// UMIPlanLauncherConformanceTests.swift - The UMI batch of the Docker run (Phase 5.3 lane EX-UMI, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// Not part of the default run, which skips it. `UMIPlanTests` pins the plan's bytes on a stand-in index record. This
/// writes the batch that `bash scripts/linux/launcher-tier.sh run` runs in the pinned image, on STAR 2.7.11b's index that
/// `rnaseq index-plan` and `rnaseq index-adopt` left for the small set, and on the reads that
/// `scripts/repro/rnaseq/fixtures/umi_reads.py` wrote: S1, whose check passes, and S2, whose Read 1 holds no motif. It runs
/// when these name what the earlier steps left, and `LUNGFISH_EX_UMI_FOLDER` is a folder that does not exist yet.
///
/// - `LUNGFISH_EX_UMI_ROOT`, the storage root that holds the set and the adopted index record
/// - `LUNGFISH_EX_UMI_EXECUTOR_MANIFEST`, the `manifest.json` that `linux_executor.py build` wrote beside the executor
/// - `LUNGFISH_EX_UMI_READS`, the folder of `staged.tsv`, the staged reads' path, bytes and SHA-256
/// - `LUNGFISH_EX_UMI_STAGING`, the staging folder that the index batch and this batch share
final class UMIPlanLauncherConformanceTests: XCTestCase {
    private func variable(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Set \(name), and the other LUNGFISH_EX_UMI_ variables the file header names, to write the batch of the Docker run.")
        }
        return value
    }

    func testWritesTheUMIBatchThatTheLauncherTierRuns() async throws {
        let out = URL(fileURLWithPath: try variable("LUNGFISH_EX_UMI_FOLDER"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "name a new folder, so that no earlier batch is reused")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let storageRoot = URL(fileURLWithPath: try variable("LUNGFISH_EX_UMI_ROOT"), isDirectory: true)
        let manifestURL = URL(fileURLWithPath: try variable("LUNGFISH_EX_UMI_EXECUTOR_MANIFEST"))
        let staging = try variable("LUNGFISH_EX_UMI_STAGING")
        let reads = URL(fileURLWithPath: try variable("LUNGFISH_EX_UMI_READS"), isDirectory: true)
        let executor = try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: Data(contentsOf: manifestURL))

        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/CHTCImage", isDirectory: true)
        let bytes = try Data(contentsOf: resources.appendingPathComponent("image-manifest.json"))
        let image = try JSONDecoder().decode(
            ExecutorPlanImageRecord.self, from: Data(contentsOf: resources.appendingPathComponent("image.json")))
        let pins = try UMIPlanPins(
            executor: executor.sourceFile(besideManifestAt: manifestURL), executorBuild: executor.build,
            imageManifest: PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count)),
            toolManifest: try ImageToolManifest.decode(bytes), star: try XCTUnwrap(STARIndexVersion(rawValue: "2.7.11b")))
        XCTAssertEqual(image.imageManifest, pins.imageManifest, "image.json pins this tool manifest")

        let sets = storageRoot.appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
        let setFolder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: sets, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == ReferenceSetManifest.folderExtension })
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let key = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            atPath: storageRoot.appendingPathComponent("rnaseq-index-records/\(manifest.id)").path).first { $0.hasPrefix("star-2.7.11b-") })
        let layout = ExecutorPlanStagingLayout(folder: staging, batch: "umi-2711")
        let index = try ExecutorPlanStagedIndex.pin(
            setID: manifest.id, key: key, store: STARIndexRecordStore(storageRoot: storageRoot), star: pins.star, layout: layout)

        let rows = try String(contentsOf: reads.appendingPathComponent("staged.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t").map(String.init) }
        let staged = try rows.map { SalmonPlanStagedRead(path: $0[0], size: try XCTUnwrap(Int64($0[1])), sha256: $0[2]) }
        XCTAssertEqual(staged.count, 4)
        let jobs = try ["S1", "S2"].enumerated().map { n, name -> (made: UMIPlanOutcome, figures: SalmonPlanSubmit.Figures) in
            let sample = SalmonPlan.stagedSample(name: name, pairs: [(staged[2 * n], staged[2 * n + 1])], model: "HiSeq X Ten")
            let made = try UMIPlan.make(UMIPlanRequest(
                setFolder: setFolder, sample: sample, kit: "quartz-seq2-x910", pins: pins, index: index))
            return (made, SalmonPlanSubmit.Figures(memoryMiB: 4096, cpus: made.threads, diskGiB: 5))
        }
        let batch = try UMIPlan.write(jobs, image: image, layout: layout, into: out.appendingPathComponent("umi-2711", isDirectory: true))
        print("EX-UMI batch: \(batch.folder.path) (\(key))")
    }
}
