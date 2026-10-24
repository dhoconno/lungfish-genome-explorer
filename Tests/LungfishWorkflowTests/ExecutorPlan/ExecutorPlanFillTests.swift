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
    }
}
