import XCTest
@testable import LungfishIO

final class ProcessingRecipeTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round-Trip Persistence

    func testRecipeRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recipe = ProcessingRecipe(
            name: "Test Pipeline",
            description: "QTrim + Dedup",
            steps: [
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20, windowSize: 4, qualityTrimMode: .cutRight),
                FASTQDerivativeOperation(kind: .deduplicate, deduplicateMode: .sequence),
            ],
            tags: ["test"]
        )

        let url = dir.appendingPathComponent("test.\(ProcessingRecipe.fileExtension)")
        try recipe.save(to: url)
        let loaded = ProcessingRecipe.load(from: url)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Test Pipeline")
        XCTAssertEqual(loaded?.steps.count, 2)
        XCTAssertEqual(loaded?.steps[0].kind, .qualityTrim)
        XCTAssertEqual(loaded?.steps[0].qualityThreshold, 20)
        XCTAssertEqual(loaded?.steps[1].kind, .deduplicate)
        XCTAssertEqual(loaded?.tags, ["test"])
    }

    // MARK: - Built-in Recipes

    func testBuiltinRecipeCount() {
        XCTAssertEqual(ProcessingRecipe.builtinRecipes.count, 4)
    }

    func testIlluminaWGSRecipe() {
        let recipe = ProcessingRecipe.illuminaWGS
        XCTAssertEqual(recipe.name, "Illumina WGS Standard")
        XCTAssertEqual(recipe.steps.count, 3)
        XCTAssertEqual(recipe.steps[0].kind, .qualityTrim)
        XCTAssertEqual(recipe.steps[1].kind, .adapterTrim)
        XCTAssertEqual(recipe.steps[2].kind, .pairedEndMerge)
        XCTAssertEqual(recipe.requiredPairingMode, .interleaved)
        XCTAssertTrue(recipe.tags.contains("illumina"))
    }

    func testOntAmpliconRecipe() {
        let recipe = ProcessingRecipe.ontAmplicon
        XCTAssertEqual(recipe.steps.count, 2)
        XCTAssertEqual(recipe.steps[0].kind, .qualityTrim)
        XCTAssertEqual(recipe.steps[1].kind, .lengthFilter)
        XCTAssertNil(recipe.requiredPairingMode)
    }

    func testPacbioHiFiRecipe() {
        let recipe = ProcessingRecipe.pacbioHiFi
        XCTAssertEqual(recipe.steps.count, 1)
        XCTAssertEqual(recipe.steps[0].kind, .deduplicate)
    }

    func testTargetedAmpliconRecipe() {
        let recipe = ProcessingRecipe.targetedAmplicon
        XCTAssertEqual(recipe.steps.count, 4)
        XCTAssertEqual(recipe.steps[0].kind, .primerRemoval)
        XCTAssertEqual(recipe.steps[3].kind, .pairedEndMerge)
    }

    // MARK: - Pipeline Summary

    func testPipelineSummary() {
        let recipe = ProcessingRecipe(
            name: "Short",
            steps: [
                FASTQDerivativeOperation(kind: .qualityTrim, qualityThreshold: 20),
                FASTQDerivativeOperation(kind: .deduplicate, deduplicateMode: .sequence),
            ]
        )
        let summary = recipe.pipelineSummary
        XCTAssertTrue(summary.hasPrefix("2 steps:"))
        XCTAssertTrue(summary.contains("qtrim-Q20"))
        XCTAssertTrue(summary.contains("dedup"))
    }

    func testEmptyPipelineSummary() {
        let recipe = ProcessingRecipe(name: "Empty", steps: [])
        XCTAssertEqual(recipe.pipelineSummary, "Empty pipeline")
    }

    // MARK: - Load Missing File

    func testLoadNonexistentRecipe() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist.recipe.json")
        let loaded = ProcessingRecipe.load(from: bogus)
        XCTAssertNil(loaded)
    }
}
