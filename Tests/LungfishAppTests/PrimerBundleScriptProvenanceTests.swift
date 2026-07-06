import XCTest

final class PrimerBundleScriptProvenanceTests: XCTestCase {
    private func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        for _ in 0..<10 {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate Package.swift above \(#filePath)")
    }

    func testPrimerBundleAuthoringScriptWritesReproducibilityProvenance() throws {
        let script = try String(
            contentsOf: try repoRoot().appendingPathComponent("scripts/build-primer-bundle.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("private let scriptToolName"))
        XCTAssertTrue(script.contains("private let scriptToolVersion"))
        XCTAssertTrue(script.contains("makeProvenanceMarkdown"))
        XCTAssertTrue(script.contains("## Command"))
        XCTAssertTrue(script.contains("## Options"))
        XCTAssertTrue(script.contains("## Inputs"))
        XCTAssertTrue(script.contains("## Outputs"))
        XCTAssertTrue(script.contains("Reference Verification"))
        XCTAssertTrue(script.contains("Wall time"))
        XCTAssertTrue(script.contains("Exit status"))
        XCTAssertTrue(script.contains("Conda environment"))
        XCTAssertTrue(script.contains("fileSHA256"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("stub the maintainer"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("replace this file"))
    }
}
