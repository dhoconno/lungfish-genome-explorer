import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ScientificCLIProvenanceCoverageTests: XCTestCase {
    func testScientificTopLevelCommandsHavePolicyEntries() {
        let nonScientificTopLevelCommands: Set<String> = [
            "version",
            "provision-tools",
            "conda",
            "debug"
        ]
        let topLevelCommands = Set(LungfishCLI.configuration.subcommands.compactMap { $0.configuration.commandName })
        let commandsExpectedToHavePolicy = topLevelCommands.subtracting(nonScientificTopLevelCommands)
        let missing = commandsExpectedToHavePolicy
            .filter { ScientificProvenancePolicy.cliCommand($0) == nil }
            .sorted()
        let stale = Set(ScientificProvenancePolicy.canonicalCLICommandNames)
            .subtracting(topLevelCommands)
            .sorted()

        XCTAssertTrue(
            stale.isEmpty,
            "CLI provenance policy references non-top-level commands: \(stale.joined(separator: ", "))"
        )
        XCTAssertTrue(missing.isEmpty, "Top-level commands missing CLI provenance policies: \(missing.joined(separator: ", "))")
    }

    func testTopLevelScientificCommandPolicyRequiresProvenance() throws {
        let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand("fastq"))

        XCTAssertTrue(policy.createsOrModifiesScientificData)
        XCTAssertTrue(policy.requiresProvenance)
        XCTAssertEqual(policy.writer, "CLIProvenanceSupport")
    }

    func testDirectScientificOutputCommandsWriteCanonicalProvenanceSidecars() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-cli-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("input.fasta")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATGGAATTCTAA")
        try FASTAWriter(url: inputURL).write([sequence])

        let convertDirectory = root.appendingPathComponent("convert", isDirectory: true)
        let translateDirectory = root.appendingPathComponent("translate", isDirectory: true)
        let searchDirectory = root.appendingPathComponent("search", isDirectory: true)
        try [convertDirectory, translateDirectory, searchDirectory].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let convertedURL = convertDirectory.appendingPathComponent("converted.fasta")
        let convert = try ConvertCommand.parse([
            inputURL.path,
            "--to", convertedURL.path,
            "--to-format", "fasta",
            "--force",
            "--quiet"
        ])
        try await convert.run()
        let convertEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: convertDirectory))
        XCTAssertEqual(convertEnvelope.workflowName, "lungfish convert")
        XCTAssertEqual(convertEnvelope.toolName, "lungfish convert")
        XCTAssertEqual(convertEnvelope.output?.path, convertedURL.path)
        XCTAssertNotNil(convertEnvelope.output?.checksumSHA256)

        let translatedURL = translateDirectory.appendingPathComponent("protein.fasta")
        let translate = try TranslateCommand.parse([
            inputURL.path,
            "--frame", "1",
            "--output", translatedURL.path,
            "--quiet"
        ])
        try await translate.run()
        let translateEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: translateDirectory))
        XCTAssertEqual(translateEnvelope.workflowName, "lungfish translate")
        XCTAssertEqual(translateEnvelope.output?.path, translatedURL.path)
        XCTAssertEqual(translateEnvelope.options.explicit["frame"]?.integerValue, 1)

        let searchURL = searchDirectory.appendingPathComponent("sites.bed")
        let search = try SearchCommand.parse([
            inputURL.path,
            "ATG",
            "--output", searchURL.path,
            "--quiet"
        ])
        try await search.run()
        let searchEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: searchDirectory))
        XCTAssertEqual(searchEnvelope.workflowName, "lungfish search")
        XCTAssertEqual(searchEnvelope.output?.path, searchURL.path)
        XCTAssertEqual(searchEnvelope.options.explicit["pattern"]?.stringValue, "ATG")
    }
}
