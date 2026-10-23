// CHTCSlicePlanFolderTests.swift - Writes the plan folder of BIO-r3 case 1 for a CHTC job or a Mac replay (CHTC lane K4, M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// The plan folder of BIO-r3 case 1: the merged recipe as `vsp2-target-enrichment` with `--remove-duplicates
/// --no-remove-ribosomal-rna`, threads 1, `bbtools`, a 4 GB heap, `illumina4` and `bgzip`, written by the emitter and
/// the folder writer for one executor binary and one image manifest. M5's CHTC job runs it with the x86_64 binary and
/// the C0 image's manifest, and the Mac replay with the macOS binary and the Mac's managed environments' manifest.
///
/// It runs only when `LUNGFISH_CHTC_PLAN_FOLDER` names the folder to write, which must not exist, and these name files:
/// `LUNGFISH_CHTC_PLAN_EXECUTOR` (the executor binary the plan pins), `LUNGFISH_CHTC_PLAN_MANIFEST` (the image manifest
/// `lungfish-executor image-manifest` wrote), `LUNGFISH_CHTC_PLAN_BUILD` (a JSON `PlanExecutorBuild`),
/// `LUNGFISH_CHTC_PLAN_R1` and `LUNGFISH_CHTC_PLAN_R2` (the slice) and `LUNGFISH_CHTC_PLAN_PANHUMAN` (the index).
final class CHTCSlicePlanFolderTests: XCTestCase {
    private static let gib: Int64 = 1_073_741_824

    private func setting(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("Set \(key) to write the CHTC slice plan folder.")
        }
        return value
    }

    func testWriteSliceCaseOnePlanFolder() async throws {
        let folder = URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_FOLDER"), isDirectory: true)
        let executor = URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_EXECUTOR"))
        let manifestFile = URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_MANIFEST"))
        let buildFile = URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_BUILD"))
        let inputs = [URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_R1")),
                      URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_R2"))]
        let index = URL(fileURLWithPath: try setting("LUNGFISH_CHTC_PLAN_PANHUMAN"))

        // The image manifest: its pin and the one version and build of each tool id it lists.
        let manifestBytes = try Data(contentsOf: manifestFile)
        let manifest = try ImageToolManifest.decode(manifestBytes)
        let pins = Set(manifest.tools.map(\.id)).sorted().compactMap { try? manifest.pin(forToolID: $0) }
        let build = try JSONDecoder().decode(PlanExecutorBuild.self, from: Data(contentsOf: buildFile))

        // R2 of BIO-r3: each switch passed as an option.
        let recipe = try XCTUnwrap(RecipeResolver.resolve(
            "vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes(),
            switchOptions: ["removeDuplicates": true, "removeRibosomalRNA": false]
        ))
        XCTAssertEqual(recipe.id, "illumina-paired-cleanup")
        let recipeFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Recipes/illumina-paired-cleanup.recipe.json")
        let database = ExecutorPlanDatabaseFile(
            record: try await RecipeDatabaseIdentity().record(databaseID: "deacon-panhuman", at: index)
        )

        let files = try inputs.map { try ExecutorPlanSourceFile.measuring($0) }
        let sample = inputs[0].lastPathComponent.replacingOccurrences(of: "_R1.fastq.gz", with: "")
        let request = ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: sample, originalFilenames: inputs.map(\.lastPathComponent),
                                     originalSizeBytes: files.reduce(0) { $0 + $1.size }),
            inputs: files, inputFormat: .pairedR1R2, recipe: recipe,
            recipeFile: try ExecutorPlanSourceFile.measuring(recipeFile),
            // R3 of BIO-r3: threads, heap, clumping tool and binning passed as options, bgzip resolved by default.
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: .bbtools, clumpifyHeapGB: 4, threads: 1,
                compressor: .bgzip, qualityBinning: .illumina4, compressionLevel: 4, threadsSource: .option,
                clumpifyHeapSource: .option, compressorSource: .default, qualityBinningSource: .option
            ),
            executorFile: try ExecutorPlanSourceFile.measuring(executor), executorBuild: build,
            imageManifest: PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: manifestBytes), size: Int64(manifestBytes.count)),
            imageTools: pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 14_400, storageSeconds: 14_400, statisticsSeconds: 3_600, graceSeconds: 60),
            databases: ["deacon-panhuman": database]
        )
        let host = ExecutorPlanHostFacts(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                         processorCount: ProcessInfo.processInfo.activeProcessorCount)
        let emission = try ExecutorPlanEmitter.emission(request, host: host)
        let plan = emission.plan

        XCTAssertEqual(plan.storage.clumpingTool, .bbtools)
        XCTAssertEqual(plan.storage.clumpifyHeapGB, 4)
        XCTAssertEqual(plan.storage.threads, 1)
        XCTAssertEqual(plan.storage.compressor, .bgzip)
        XCTAssertEqual(plan.storage.qualityBinning, .illumina4)
        XCTAssertEqual(plan.recipe?.turnedOffSteps.map(\.switchID), ["removeRibosomalRNA"])
        let databaseEntry = try XCTUnwrap(plan.entries.first { $0.role == .database })
        XCTAssertEqual(databaseEntry.relativePath, "databases/deacon-panhuman/\(index.lastPathComponent)")
        XCTAssertEqual(databaseEntry.sha256, database.file.sha256)

        let planFile = try ExecutorPlanFolderWriter.write(emission, into: folder)
        XCTAssertEqual(try ExecutionPlan.decode(Data(contentsOf: planFile)), plan)
        let summary: [String: String] = [
            "planFile": planFile.path,
            "planSHA256": try PortableDigest.sha256Hex(ofFileAt: planFile),
            "databaseRelativePath": databaseEntry.relativePath,
            "databaseSHA256": databaseEntry.sha256,
            "databaseSize": "\(databaseEntry.size)",
            "databaseLockPinned": "\(databaseEntry.database?.lockPinned ?? false)",
            "executorSHA256": plan.entries.first { $0.role == .executor }?.sha256 ?? "",
            "imageManifestSHA256": plan.imageManifest.sha256,
            "imageManifestSize": "\(plan.imageManifest.size)",
            "tools": plan.tools.map { "\($0.id) \($0.version) \($0.build)" }.joined(separator: "; "),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-summary.json"))
    }
}
