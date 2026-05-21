import XCTest
@testable import LungfishWorkflow

final class WorkflowPackageManifestTests: XCTestCase {
    func testManifestDecodesNextflowSnakemakeAndCommandRunnerKinds() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "org.example.hello-nextflow",
          "name": "Hello Nextflow",
          "version": "1.0.0",
          "category": "Templates",
          "maturity": "user",
          "description": "Template workflow",
          "runner": { "kind": "nextflow", "entrypoint": "main.nf" },
          "runtime": { "kind": "conda", "environmentFile": "environment.yml" },
          "inputs": [
            { "id": "reference", "name": "Reference", "bundleTypes": ["lungfishref"], "required": true },
            { "id": "reads", "name": "Reads", "bundleTypes": ["lungfishfastq"], "required": true }
          ],
          "outputs": [
            { "id": "result", "name": "Result", "bundleType": "lungfishref", "pathTemplate": "outputs/hello.lungfishref" }
          ],
          "requiredPluginPackIDs": ["lungfish-tools"]
        }
        """

        let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.runner.kind, .nextflow)
        XCTAssertEqual(manifest.runtime.kind, .conda)
        XCTAssertEqual(manifest.inputs.map(\.bundleTypes), [[.lungfishref], [.lungfishfastq]])
        XCTAssertEqual(manifest.outputs.map(\.bundleType), [.lungfishref])
        XCTAssertEqual(manifest.requiredPluginPackIDs, ["lungfish-tools"])
    }

    func testHelloWorldNextflowTemplateValidatesAsThreeStepReferenceProducingPackage() throws {
        let packageURL = examplesDirectory()
            .appendingPathComponent("hello-world-nextflow.lungfishflowpkg", isDirectory: true)

        let result = try WorkflowPackageValidator.validatePackage(at: packageURL)

        XCTAssertEqual(result.manifest.id, "org.lungfish.templates.hello-world-nextflow")
        XCTAssertEqual(result.manifest.runner.kind, .nextflow)
        XCTAssertEqual(result.manifest.inputs.map(\.bundleTypes), [[.lungfishref], [.lungfishfastq]])
        XCTAssertEqual(result.manifest.outputs.map(\.bundleType), [.lungfishref])
        XCTAssertEqual(result.manifest.outputs.map(\.pathTemplate), ["hello-world-nextflow.lungfishref"])
        XCTAssertEqual(result.manifest.template?.stepCount, 3)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testHelloWorldSnakemakeTemplateValidatesAsThreeStepReferenceProducingPackage() throws {
        let packageURL = examplesDirectory()
            .appendingPathComponent("hello-world-snakemake.lungfishflowpkg", isDirectory: true)

        let result = try WorkflowPackageValidator.validatePackage(at: packageURL)

        XCTAssertEqual(result.manifest.id, "org.lungfish.templates.hello-world-snakemake")
        XCTAssertEqual(result.manifest.runner.kind, .snakemake)
        XCTAssertEqual(result.manifest.inputs.map(\.bundleTypes), [[.lungfishref], [.lungfishfastq]])
        XCTAssertEqual(result.manifest.outputs.map(\.bundleType), [.lungfishref])
        XCTAssertEqual(result.manifest.outputs.map(\.pathTemplate), ["hello-world-snakemake.lungfishref"])
        XCTAssertEqual(result.manifest.template?.stepCount, 3)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testHelloWorldSnakemakeTemplateWritesFastaWithoutIndentedHeredoc() throws {
        let snakefile = examplesDirectory()
            .appendingPathComponent("hello-world-snakemake.lungfishflowpkg", isDirectory: true)
            .appendingPathComponent("Snakefile")
        let source = try String(contentsOf: snakefile, encoding: .utf8)

        XCTAssertTrue(source.contains("Path(output[0]).write_text"))
        XCTAssertFalse(source.contains("cat > {output} <<'FASTA'"))
    }

    func testValidatorRejectsMissingRunnerEntrypoint() throws {
        let root = try temporaryDirectory()
        let packageURL = root.appendingPathComponent("broken.lungfishflowpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "org.example.broken",
          "name": "Broken",
          "version": "1.0.0",
          "category": "Templates",
          "maturity": "user",
          "runner": { "kind": "snakemake", "entrypoint": "Snakefile" },
          "inputs": [
            { "id": "reference", "name": "Reference", "bundleTypes": ["lungfishref"], "required": true }
          ],
          "outputs": [
            { "id": "result", "name": "Result", "bundleType": "lungfishref", "pathTemplate": "outputs/result.lungfishref" }
          ]
        }
        """
        try manifest.write(to: packageURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WorkflowPackageValidator.validatePackage(at: packageURL)) { error in
            XCTAssertEqual(error as? WorkflowPackageValidationError, .missingRunnerEntrypoint("Snakefile"))
        }
    }

    private func examplesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowPackageManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
