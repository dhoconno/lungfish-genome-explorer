// ExecutorPlanBatchLauncherConformanceTests.swift - Writes the schema 2 batch that the launcher tier runs in Docker
// (Phase 5.3 lane EX-SUBMIT, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// The proof of milestone 2 needs a real batch and a real executor, so this test writes them for
/// `bash scripts/linux/launcher-tier.sh run`. It runs only when `LUNGFISH_EX_SUBMIT_FOLDER` names a folder to make, which
/// must not exist, and `LUNGFISH_EX_SUBMIT_EXECUTOR` names the stripped x86-64 executor that `scripts/linux/portable-tier.sh`
/// builds. It writes `ex-submit/` (the batch) and `data/` (the files `staging-files.json` lists below the staging folder,
/// except the image, which a Docker run reads from its Docker image). The stand-in test beside it, in
/// ``ExecutorPlanBatchSchemaTwoTests``, runs by default.
final class ExecutorPlanBatchLauncherConformanceTests: XCTestCase {
    private typealias Fixture = ExecutorPlanIndexShapeFixture

    private func setting(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("Set \(key) to write the batch the launcher tier runs.")
        }
        return value
    }

    func testWriteTheIndexShapedBatchAndItsDataFolder() throws {
        let out = URL(fileURLWithPath: try setting("LUNGFISH_EX_SUBMIT_FOLDER"), isDirectory: true)
        let executorFile = URL(fileURLWithPath: try setting("LUNGFISH_EX_SUBMIT_EXECUTOR"))
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: out.path), "\(out.path) must not exist")

        // The pinned image's record and manifest, and the one version and build of seqkit and pigz in it.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/CHTCImage")
        let image = try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: Data(contentsOf: resources.appendingPathComponent("image.json")))
        let manifestBytes = try Data(contentsOf: resources.appendingPathComponent("image-manifest.json"))
        XCTAssertEqual(image.imageManifest, PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: manifestBytes), size: Int64(manifestBytes.count)))
        let manifest = try ImageToolManifest.decode(manifestBytes)

        let inputs = out.appendingPathComponent("inputs", isDirectory: true)
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data(Fixture.referenceText.utf8).write(to: inputs.appendingPathComponent("ref.fa"))
        try Data(Fixture.listText.utf8).write(to: inputs.appendingPathComponent("ids.txt"))
        let executor = try Fixture.Source(executorFile)
        let reference = try Fixture.Source(inputs.appendingPathComponent("ref.fa"))
        let list = try Fixture.Source(inputs.appendingPathComponent("ids.txt"))
        let job = Fixture.job(
            executor: executor, reference: reference, list: list, seqkit: try manifest.pin(forToolID: "seqkit"),
            pigz: try manifest.pin(forToolID: "pigz"), imageManifest: image.imageManifest
        )
        let layout = ExecutorPlanStagingLayout(folder: "/staging/groups/lge/ex-submit", batch: "ex-submit")
        let folder = out.appendingPathComponent("ex-submit", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([job], image: image, layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["index"])

        // The data folder holds each shared file at its path below the staging folder, as run-local.sh reads it.
        let data = out.appendingPathComponent("data", isDirectory: true)
        let held = ["executor": executor.url, "reference": reference.url, "barcodeList": URL(fileURLWithPath: inputs.appendingPathComponent("ids.txt").path)]
        for file in batch.files where held[file.role] != nil {
            let destination = data.appendingPathComponent(String(file.stagingPath.dropFirst(layout.folder.count + 1)))
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: try XCTUnwrap(held[file.role]), to: destination)
            if file.role == "executor" { try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path) }
            XCTAssertEqual(try PortableDigest.sha256Hex(ofFileAt: destination), file.sha256, destination.lastPathComponent)
        }

        // An index reads no reads, so the job's row names the three shared files and nothing below batches/.
        let rows = try String(contentsOf: folder.appendingPathComponent("jobs.tsv"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 2)
        let placements = rows[1].split(separator: "\t").dropFirst(3).map(String.init)
        XCTAssertEqual(placements.map { String($0.split(separator: "=").last ?? "") },
                       ["bin/lungfish-executor", Fixture.referencePath, Fixture.listPath], "\(placements)")
        XCTAssertFalse(placements.contains { $0.hasPrefix("batches/") }, "\(placements)")
    }
}
