import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ScientificCLIProvenanceCoverageTests: XCTestCase {
    func testScientificTopLevelCommandsHavePolicyEntries() {
        let scientificCommands = [
            "convert", "analyze", "translate", "search", "universal-search", "extract",
            "fastq", "workflow", "run-headless", "fetch", "bundle", "project", "blast",
            "esviritu", "taxtriage", "align", "msa", "tree", "assemble", "orient",
            "map", "import", "import-fastq", "ops", "provenance", "bam", "variants",
            "gatk", "nao-mgs", "freyja", "nvd", "cz-id", "metadata", "build-db",
            "markdup", "primers"
        ]
        let topLevelCommands = Set(LungfishCLI.configuration.subcommands.map { $0.configuration.commandName })
        let stalePolicyTestCommands = scientificCommands.filter { !topLevelCommands.contains($0) }
        let missing = scientificCommands.filter { ScientificProvenancePolicy.cliCommand($0) == nil }

        XCTAssertTrue(
            stalePolicyTestCommands.isEmpty,
            "Policy test references non-top-level CLI commands: \(stalePolicyTestCommands.joined(separator: ", "))"
        )
        XCTAssertTrue(missing.isEmpty, "Missing CLI provenance policies: \(missing.joined(separator: ", "))")
    }

    func testTopLevelScientificCommandPolicyRequiresProvenance() throws {
        let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand("fastq"))

        XCTAssertTrue(policy.createsOrModifiesScientificData)
        XCTAssertTrue(policy.requiresProvenance)
        XCTAssertEqual(policy.writer, "CLIProvenanceSupport")
    }
}
