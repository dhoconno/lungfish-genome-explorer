// SoloPlanLauncherConformanceTests.swift - The STARsolo batches of the Docker run (Phase 5.3 lane SOLO-PLAN, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// Not part of the default run, which skips it. `SoloPlanTests` pins the plans' bytes on stand-in index records. This
/// writes one batch a preset that `bash scripts/linux/launcher-tier.sh run` runs in the pinned image, on the variant index
/// that `rnaseq index-plan --tenx-filter` and `rnaseq index-adopt` left, with the fixture's reads staged, so the real
/// STARsolo reads the staged index and the barcode lists. It runs when these name what the earlier steps left, and
/// `LUNGFISH_SOLO_FOLDER` is a folder that does not exist yet.
///
/// - `LUNGFISH_SOLO_SET`, the set's folder, and `LUNGFISH_SOLO_RECORDS`, the storage root of the adopted index record
/// - `LUNGFISH_SOLO_EXECUTOR_MANIFEST`, the `manifest.json` that `linux_executor.py build` wrote beside the executor
/// - `LUNGFISH_SOLO_STAGING`, the staging folder the index batch used, and `LUNGFISH_SOLO_737K`, the whole 737K list
final class SoloPlanLauncherConformanceTests: XCTestCase {
    private func variable(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Set \(name), and the other LUNGFISH_SOLO_ variables the file header names, to write the batches of the Docker run.")
        }
        return value
    }

    func testWritesTheSTARsoloBatchesThatTheLauncherTierRuns() throws {
        let out = URL(fileURLWithPath: try variable("LUNGFISH_SOLO_FOLDER"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "name a new folder, so that no earlier batch is reused")
        let setFolder = URL(fileURLWithPath: try variable("LUNGFISH_SOLO_SET"), isDirectory: true)
        let records = URL(fileURLWithPath: try variable("LUNGFISH_SOLO_RECORDS"), isDirectory: true)
        let manifestURL = URL(fileURLWithPath: try variable("LUNGFISH_SOLO_EXECUTOR_MANIFEST"))
        let staging = try variable("LUNGFISH_SOLO_STAGING")
        let list737K = try ExecutorPlanSourceFile.measuring(URL(fileURLWithPath: try variable("LUNGFISH_SOLO_737K")))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let executor = try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: Data(contentsOf: manifestURL))
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/CHTCImage", isDirectory: true)
        let toolBytes = try Data(contentsOf: resources.appendingPathComponent("image-manifest.json"))
        let image = try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: Data(contentsOf: resources.appendingPathComponent("image.json")))
        let pin = PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: toolBytes), size: Int64(toolBytes.count))
        XCTAssertEqual(image.imageManifest, pin, "image.json pins this tool manifest")
        let pins = try SoloPlanPins(executor: executor.sourceFile(besideManifestAt: manifestURL), executorBuild: executor.build,
                                    imageManifest: pin, toolManifest: try ImageToolManifest.decode(toolBytes))
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let key = STARIndexKey.folderName(star: SoloPlan.starVersion, nbases: 6, sparseD: 2, filter: .mkgtf300)
        for preset in SoloPlanPreset.allCases {
            let name = "solo-\(preset.rawValue.dropFirst("tenx-".count))"
            let layout = ExecutorPlanStagingLayout(folder: staging, batch: name)
            let index = try ExecutorPlanStagedIndex.pin(
                setID: manifest.id, key: key, store: STARIndexRecordStore(storageRoot: records), star: pins.star, layout: layout)
            let reads = try SoloPlanTests.sample(preset)
            var sample = reads
            sample.stagedPaths = reads.stagedPaths?.map { $0.replacingOccurrences(of: SoloPlanTests.staging, with: staging) }
            let made = try SoloPlan.make(SoloPlanRequest(
                setFolder: setFolder, sample: sample, pins: pins, preset: preset, index: index,
                suppliedList: preset == .fivePrimeV2 ? list737K : nil))
            let figures = try SoloPlanSubmit.figures(for: manifest, made: made, memoryMiB: 4096, cpus: 8, diskGiB: 5)
            let batch = try SoloPlanSubmit.write([(made, figures)], image: image, layout: layout,
                                                 into: out.appendingPathComponent(name, isDirectory: true))
            XCTAssertTrue(batch.files.filter { $0.stagingPath.contains("/index/staged/") }.allSatisfy { $0.source == nil })
            print("SOLO-PLAN batch: \(batch.folder.path) (\(key), \(preset.rawValue), list \(made.barcodeList.list.name) \(made.barcodeList.source.rawValue))")
        }
    }
}
