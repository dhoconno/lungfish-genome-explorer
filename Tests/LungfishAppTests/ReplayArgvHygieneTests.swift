import XCTest
import LungfishTestSupport

/// Source-guard tests enforcing the binding replay-argv rule: GUI-triggered
/// provenance must record `lungfish-cli` as argv[0]. Historically the haplotype
/// manager emitted `lungfish` and the genotype annotation/export provenance
/// emitted `lungfish-gui`; these are replay strings (not real process launches),
/// so normalizing argv[0] is the fix. We assert by scanning the source so the
/// guard survives refactors of the surrounding code.
final class ReplayArgvHygieneTests: XCTestCase {
    /// Walk up from this test file until we find the directory containing
    /// `Package.swift`, which is the repo (package) root.
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

    func testNoLungfishGuiArgvRemainsInGenotypeProvenanceSources() throws {
        let repoRoot = try repoRoot()
        // Sanity check that the root resolved to something containing the package manifest.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path),
            "Resolved repo root \(repoRoot.path) does not contain Package.swift"
        )

        // The genotype side reads every file of the LungfishGenotypeUI module, so the rule
        // keeps covering provenance code that moves into a new file. The App file is read alone.
        let haplotypeManagerPath =
            "Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift"
        let sources: [(rel: String, text: String)] = [
            ("Sources/LungfishGenotypeUI", try combinedGenotypeUISource()),
            (
                haplotypeManagerPath,
                try readRepositorySource(repoRoot.appendingPathComponent(haplotypeManagerPath))
            ),
        ]
        for (rel, text) in sources {
            XCTAssertFalse(
                text.contains("\"lungfish-gui\""),
                "\(rel) still has a lungfish-gui replay argv"
            )
            // Guard the bare "lungfish" argv[0] forms. Allowed argv[0] values like
            // "lungfish-cli"/"lungfish-tools" stay intact because we only match the
            // exact-quote argv-array prefixes below.
            XCTAssertFalse(
                text.contains("[\"lungfish\","),
                "\(rel) still has a bare lungfish argv[0]"
            )
            XCTAssertFalse(
                text.contains("[\"lungfish\"]"),
                "\(rel) still has a bare lungfish argv[0]"
            )
            XCTAssertFalse(
                text.contains("= [\"lungfish\"] +"),
                "\(rel) still has a bare lungfish argv[0] in a shared helper"
            )
        }
    }
}
