// ExecutorPlanFillTests.swift - The recipe template, the per-sample fill and the shared plan folder (CHTC C4 lane F)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorPlanFillTests: XCTestCase {
    /// The SHA-256 and byte count of the Mac's per-sample plan of `goldenRequest()`, recorded at 2667f6cad, before the
    /// plan request was split into a template and a fill (ARCH-fill F6). A change to the VSP2 recipe, the emitter or the
    /// plan types changes them, and that change needs its own prediction of the plan bytes.
    private static let goldenSHA256 = "b61f5751fab34f809d49abd248f5f3fce4f97e4946d48fc99a6cd19a3c7633e5"
    private static let goldenByteCount = 11060

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanFill")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// VSP2 as the registry resolves it, with its deacon scrub reading the stand-in index `test-panhuman`.
    private func vsp2() throws -> Recipe {
        var recipe = try XCTUnwrap(RecipeResolver.resolve("vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes()))
        for position in recipe.steps.indices where recipe.steps[position].type == "deacon-scrub" {
            recipe.steps[position].params?["database"] = .string("test-panhuman")
        }
        return recipe
    }

    /// A stand-in panhuman index of fixed bytes, made through the engine's own database record.
    private func panhuman() async throws -> ExecutorPlanDatabaseFile {
        let folder = root.appendingPathComponent("databases/test-panhuman", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("panhuman-1.k31w15.idx")
        try Data("deacon index test-panhuman".utf8).write(to: index)
        return ExecutorPlanDatabaseFile(record: try await RecipeDatabaseIdentity().record(databaseID: "test-panhuman", at: index))
    }

    /// Sample S: an R1/R2 pair of fixed bytes, VSP2 with the stand-in index, `bbtools`, threads 1, a 4 GB heap.
    private func goldenRequest() async throws -> ExecutorPlanRequest {
        var request = try ExecutorPlanTestSupport.request(
            root: root, "S", inputs: ExecutorPlanTestSupport.writePair(root: root, "S"), clumping: .bbtools, recipe: vsp2()
        )
        request.databases = ["test-panhuman": try await panhuman()]
        return request
    }

    /// V5's fill golden (ARCH-fill F6): the Mac's per-sample plan has the bytes recorded before the split.
    func testFillEqualsMacPerSamplePlan() async throws {
        let request = try await goldenRequest()
        let mac = try ExecutorPlanEmitter.emission(request, host: ExecutorPlanTestSupport.mac24).plan.encoded()
        XCTAssertEqual(PortableDigest.sha256Hex(of: mac), Self.goldenSHA256)
        XCTAssertEqual(mac.count, Self.goldenByteCount)

        // The fill's half (ARCH-fill F6, step 2): the template filled with the values a sample sheet gives, as a caller
        // with no plan request holds them, has the recorded bytes, and so does the plan file of the per-sample folder.
        let recipeTemplate = try ExecutorPlanEmitter.template(request.templateRequest, host: ExecutorPlanTestSupport.mac24)
        let pair = request.inputs.map(\.url)
        let measured = try pair.map { try ExecutorPlanSourceFile.measuring($0) }
        let fill = PlanSampleFill(
            sampleName: "S", originalFilenames: pair.map(\.lastPathComponent),
            inputs: measured.map { PlanInputFile(sha256: $0.sha256, size: $0.size) }
        )
        let filled = try recipeTemplate.template.fill(fill).encoded()
        XCTAssertEqual(PortableDigest.sha256Hex(of: filled), Self.goldenSHA256)
        XCTAssertEqual(filled, mac)
        let planFile = try ExecutorPlanFolderWriter.write(
            recipeTemplate.emission(for: ExecutorPlanSampleRow(sampleName: "S", inputs: measured)),
            into: root.appendingPathComponent("plan-S", isDirectory: true)
        )
        XCTAssertEqual(try Data(contentsOf: planFile), mac)
    }

    /// BIO's fill golden of OQ-9 (ARCH-fill F2): two sheets that differ only in `request_disk` give plans of equal
    /// bytes, so the value reaches no argv and no step's environment either, and the split hands each disk value,
    /// unchanged, to the submit side.
    func testFillSheetsDifferingOnlyInDiskGiveEqualPlans() async throws {
        let request = try await goldenRequest()
        let recipeTemplate = try ExecutorPlanEmitter.template(request.templateRequest, host: ExecutorPlanTestSupport.mac24)
        var sheet: [ExecutorPlanSampleRow] = []
        for name in ["S", "T"] {
            let files = try ExecutorPlanTestSupport.writePair(root: root, name).map { try ExecutorPlanSourceFile.measuring($0) }
            sheet.append(ExecutorPlanSampleRow(sampleName: name, inputs: files, sampleSheet: [PlanKeyValue(key: "site", value: "Madison")]))
        }
        var small = sheet
        var large = sheet
        small[0].requestDiskGiB = 300
        small[1].requestDiskGiB = 120
        large[0].requestDiskGiB = 900
        large[1].requestDiskGiB = nil
        for index in sheet.indices {
            let smallBytes = try recipeTemplate.emission(for: small[index]).plan.encoded()
            let largeBytes = try recipeTemplate.emission(for: large[index]).plan.encoded()
            XCTAssertEqual(smallBytes, largeBytes, sheet[index].sampleName)
            XCTAssertEqual(small[index].split().fill, large[index].split().fill)
            XCTAssertEqual(small[index].split().submit, ExecutorPlanSubmitValues(
                sampleName: sheet[index].sampleName, requestDiskGiB: small[index].requestDiskGiB
            ))
            let text = String(decoding: largeBytes, as: UTF8.self)
            for key in ["request_disk", "requestDisk", "RequestDisk"] {
                XCTAssertFalse(text.contains(key), key)
            }
        }
        XCTAssertEqual(small.map { $0.split().submit.requestDiskGiB }, [300, 120])
        XCTAssertEqual(large.map { $0.split().submit.requestDiskGiB }, [900, nil])
    }

    /// ARCH-fill F3: one template filled for two samples that differ in name, file names, labels, input digests and
    /// input sizes gives plans equal in every field but `sample` and the input entries' SHA-256 and size. The input
    /// files' paths reach the folder writer's sources and no plan field.
    func testFillWritesPathsNamesAndDigestsOnly() async throws {
        let request = try await goldenRequest()
        let recipeTemplate = try ExecutorPlanEmitter.template(request.templateRequest, host: ExecutorPlanTestSupport.mac24)
        let first = ExecutorPlanSampleRow(sampleName: "S", inputs: request.inputs, sampleSheet: [PlanKeyValue(key: "site", value: "Madison")])
        let folder = root.appendingPathComponent("run-7", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("Patient-7_L001_R1.fastq")
        let r2 = folder.appendingPathComponent("Patient-7_L001_R2.fastq")
        try "@a/1\nACGTACGTACGTAAAA\n+\nIIIIIIIIIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@a/2\nTTTTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        let second = ExecutorPlanSampleRow(
            sampleName: "Patient-7", inputs: try [r1, r2].map { try ExecutorPlanSourceFile.measuring($0) },
            sampleSheet: [PlanKeyValue(key: "site", value: "Milwaukee"), PlanKeyValue(key: "collected", value: "2026-10-20")]
        )
        let emissions = try [first, second].map { try recipeTemplate.emission(for: $0) }
        let a = try ExecutionPlan.decode(emissions[0].plan.encoded())
        let b = try ExecutionPlan.decode(emissions[1].plan.encoded())
        XCTAssertEqual(a.schemaVersion, b.schemaVersion)
        XCTAssertEqual(a.entries.filter { $0.role != .input }, b.entries.filter { $0.role != .input })
        XCTAssertEqual(Set(a.entries.filter { $0.role != .input }.map(\.role)), [.executor, .recipe, .database])
        XCTAssertEqual(a.entries.map(\.relativePath), b.entries.map(\.relativePath))
        XCTAssertEqual(a.steps, b.steps)
        XCTAssertEqual(a.tools, b.tools)
        XCTAssertEqual(a.storage, b.storage)
        XCTAssertEqual(a.clumping, b.clumping)
        XCTAssertEqual(a.executor, b.executor)
        XCTAssertEqual(a.imageManifest, b.imageManifest)
        XCTAssertEqual(a.recipe, b.recipe)
        XCTAssertEqual(a.graceSeconds, b.graceSeconds)
        for (plan, row) in zip([a, b], [first, second]) {
            let inputs = plan.entries.filter { $0.role == .input }
            XCTAssertEqual(inputs.map(\.sha256), row.inputs.map(\.sha256))
            XCTAssertEqual(inputs.map(\.size), row.inputs.map(\.size))
            XCTAssertEqual(plan.sample, PlanSampleValues(
                sampleName: row.sampleName, originalFilenames: row.inputs.map(\.url.lastPathComponent),
                originalSizeBytes: row.inputs.reduce(0) { $0 + $1.size }, sampleSheet: row.sampleSheet
            ))
        }
        XCTAssertNotEqual(a.entries.filter { $0.role == .input }.map(\.sha256), b.entries.filter { $0.role == .input }.map(\.sha256))
        XCTAssertNotEqual(a.sample.originalSizeBytes, b.sample.originalSizeBytes)
        // The paths go to the folder writer and into no plan field.
        XCTAssertEqual(emissions[1].sources["inputs/R1.fastq"], r1)
        XCTAssertEqual(emissions[1].sources["inputs/R2.fastq"], r2)
        XCTAssertFalse(String(decoding: try b.encoded(), as: UTF8.self).contains(root.path))
    }

    /// ARCH-fill F4, the Mac's half: a fill refusal reaches the Mac as an `ExecutorPlanError` with the fill's field and
    /// words, and a request whose sample states another size than its inputs hold is refused.
    func testFillRefusalReachesTheMacWithItsFieldAndWords() async throws {
        let request = try await goldenRequest()
        let recipeTemplate = try ExecutorPlanEmitter.template(request.templateRequest, host: ExecutorPlanTestSupport.mac24)
        var renamed = ExecutorPlanSampleRow(sampleName: "S", inputs: request.inputs)
        renamed.originalFilenames[0] = "S_R1.fastq.gz"
        XCTAssertThrowsError(try recipeTemplate.emission(for: renamed)) { error in
            XCTAssertEqual(error as? ExecutorPlanError, ExecutorPlanError(
                field: "sample.originalFilenames",
                reason: "The file S_R1.fastq.gz takes the suffix .fastq.gz, and this template's input inputs/R1.fastq takes .fastq. A sample whose files take another suffix needs a template of its own."
            ))
        }
        var stale = request
        stale.sample.originalSizeBytes += 1
        XCTAssertThrowsError(try ExecutorPlanEmitter.emission(stale, host: ExecutorPlanTestSupport.mac24)) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.field, "sample.originalSizeBytes")
        }
    }

    /// ARCH point 2 and Q-C4-5 (ARCH-fill F8): the shared folder holds no executor and no database, names each in
    /// `staging.json` by SHA-256 and size beside the image values it was given, and its plan file has the per-sample
    /// folder's bytes. The image's values are in `staging.json` and in no plan field.
    func testSharedFolderCopiesNoDatabaseOrExecutor() async throws {
        let request = try await goldenRequest()
        let emission = try ExecutorPlanEmitter.emission(request, host: ExecutorPlanTestSupport.mac24)
        let image = ExecutorPlanImageFile(
            fileName: "lge-c0-tools-c42530259944.sif", sha256: String(repeating: "c", count: 64), size: 392_368_128
        )
        let perSample = try ExecutorPlanFolderWriter.write(emission, into: root.appendingPathComponent("per-sample", isDirectory: true))
        let folder = root.appendingPathComponent("shared", isDirectory: true)
        let shared = try ExecutorPlanFolderWriter.writeShared(emission, image: image, into: folder)
        let planBytes = try Data(contentsOf: shared)
        XCTAssertEqual(planBytes, try Data(contentsOf: perSample))

        let entries = emission.plan.entries
        let kept = entries.filter { $0.role == .executor || $0.role == .database }
        XCTAssertEqual(Set(kept.map(\.role)), [.executor, .database])
        let copied = entries.filter { $0.role == .recipe || $0.role == .input }.map(\.relativePath)
        XCTAssertEqual(try regularFiles(in: folder), (copied + [ExecutorPlanFolderWriter.planFileName, ExecutorPlanStaging.fileName]).sorted())
        for entry in kept {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.relativePath).path), entry.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: perSample.deletingLastPathComponent().appendingPathComponent(entry.relativePath).path
            ), entry.relativePath)
        }
        let staging = try JSONDecoder().decode(
            ExecutorPlanStaging.self, from: Data(contentsOf: folder.appendingPathComponent(ExecutorPlanStaging.fileName))
        )
        XCTAssertEqual(staging, ExecutorPlanStaging(sharedFiles: kept.map {
            ExecutorPlanSharedFile(role: $0.role, relativePath: $0.relativePath, sha256: $0.sha256, size: $0.size)
        }, image: image))
        let planText = String(decoding: planBytes, as: UTF8.self)
        XCTAssertFalse(planText.contains(image.fileName))
        XCTAssertFalse(planText.contains(image.sha256))
        let resolver = try PlanResourceResolver(planFile: shared)
        for entry in entries where entry.role == .recipe || entry.role == .input {
            XCTAssertNoThrow(try resolver.verify(entry), entry.relativePath)
        }

        let refused = root.appendingPathComponent("refused", isDirectory: true)
        var nested = image
        nested.fileName = "images/lge.sif"
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.writeShared(emission, image: nested, into: refused)) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.field, "staging.image.fileName")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    }

    /// Every regular file under `folder`, by its path relative to `folder`, sorted.
    private func regularFiles(in folder: URL) throws -> [String] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var paths: [String] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                paths.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
            }
        }
        return paths.sorted()
    }
}
