import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Covers the `msa discriminating-sites` subcommand with rows already inside
/// one bundle. The `--exclusion-sequences` path runs the managed MAFFT, so it
/// is exercised by the real-data run rather than here.
final class MSADiscriminatingSitesCommandTests: XCTestCase {
    /// Two targets agreeing on A, two exclusions carrying G at columns 1 and 5,
    /// with a conserved stretch between them.
    private let alignment = """
    >t1
    ACGTACGT
    >t2
    ACGTACGT
    >x1
    GCGTGCGT
    >x2
    GCGTGCGT

    """

    /// The sidecar is written with ISO8601 dates, so a reader must match it.
    private func provenanceDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/test-artifacts/MSADiscriminatingSites-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Imports the fixture bundle once per temp directory, so a test that runs
    /// the command repeatedly exercises output overwriting rather than tripping
    /// over an existing bundle.
    private func bundle(in tempDir: URL) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("panel.lungfishmsa", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundleURL.path) { return bundleURL }
        return try makeDiscriminatingSitesMSABundle(in: tempDir, contents: alignment, name: "panel")
    }

    private func run(
        arguments: [String],
        in tempDir: URL
    ) throws -> (lines: [String], output: URL) {
        let bundleURL = try bundle(in: tempDir)
        let outputURL = tempDir.appendingPathComponent("sites.tsv")
        let command = try MSACommand.DiscriminatingSitesSubcommand.parse(
            [bundleURL.path] + arguments + ["--output", outputURL.path])
        let recorder = DiscriminatingSitesLineRecorder()
        try command.executeForTesting { recorder.append($0) }
        return (recorder.lines(), outputURL)
    }

    func testWritesSiteWindowAndJSONTablesWithProvenance() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try run(arguments: ["--exclusions", "x1,x2", "--window-length", "8"], in: tempDir)

        let sites = try String(contentsOf: result.output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(sites.first, DiscriminatingSitesReportFormatter.siteColumns.joined(separator: "\t"))
        // Columns 1 and 5 discriminate; the conserved bases between them do not.
        XCTAssertEqual(sites.count, 3)
        XCTAssertTrue(sites[1].hasPrefix("1\t1\tA\t2\t"))
        XCTAssertTrue(sites[2].hasPrefix("5\t5\tA\t2\t"))

        let windows = try String(
            contentsOf: tempDir.appendingPathComponent("sites.windows.tsv"), encoding: .utf8)
        XCTAssertTrue(windows.contains("1\t5\t1\t5\t2\t1;5"))

        let report = try JSONDecoder().decode(
            DiscriminatingSitesAnalysis.Report.self,
            from: try Data(contentsOf: tempDir.appendingPathComponent("sites.json")))
        XCTAssertEqual(report.targetNames, ["t1", "t2"])
        XCTAssertEqual(report.exclusionNames, ["x1", "x2"])
        XCTAssertEqual(report.siteCount, 2)

        let provenance = try provenanceDecoder().decode(
            MSADiscriminatingSitesProvenance.self,
            from: try Data(contentsOf: result.output.appendingPathExtension("lungfish-provenance.json")))
        XCTAssertEqual(provenance.actionID, "msa.inspection.discriminating-sites")
        XCTAssertEqual(provenance.discriminatingColumnCount, 2)
        XCTAssertEqual(provenance.outputFiles.count, 3)
        XCTAssertNil(provenance.exclusionSequencesFile)
        XCTAssertTrue(provenance.reproducibleCommand.contains("msa discriminating-sites"))
        XCTAssertEqual(provenance.options.minimumExclusionDifferences, 2)
    }

    func testTargetsDefaultToTheRowsNotNamedAsExclusions() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try run(arguments: ["--exclusions", "x1,x2"], in: tempDir)

        XCTAssertTrue(result.lines.contains("Targets: 2 (template t1)"))
        XCTAssertTrue(result.lines.contains("Exclusions: 2"))
        XCTAssertTrue(result.lines.contains("Discriminating columns: 2"))
    }

    func testTemplateOptionSelectsTheReportedCoordinateRow() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try run(
            arguments: ["--exclusions", "x1,x2", "--template", "t2"], in: tempDir)

        XCTAssertTrue(result.lines.contains("Targets: 2 (template t2)"))
    }

    func testRejectsATemplateThatIsNotATargetRow() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(
            try run(arguments: ["--exclusions", "x1,x2", "--template", "x1"], in: tempDir))
    }

    func testRejectsARowNamedAsBothTargetAndExclusion() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(
            try run(arguments: ["--targets", "t1,x1", "--exclusions", "x1"], in: tempDir))
    }

    func testRejectsAnUnknownRowName() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(try run(arguments: ["--exclusions", "nope"], in: tempDir))
    }

    func testRequiresAnExclusionSelection() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(try run(arguments: [], in: tempDir))
    }

    func testRejectsBothExclusionSourcesAtOnce() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(try run(
            arguments: ["--exclusions", "x1", "--exclusion-sequences", "/nonexistent.fasta"],
            in: tempDir))
    }

    func testRefusesToOverwriteWithoutForce() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try run(arguments: ["--exclusions", "x1,x2"], in: tempDir)
        XCTAssertThrowsError(try run(arguments: ["--exclusions", "x1,x2"], in: tempDir))
        XCTAssertNoThrow(try run(arguments: ["--exclusions", "x1,x2", "--force"], in: tempDir))
    }

    func testEmitsMachineReadableEventsUnderJSONFormat() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try run(
            arguments: ["--exclusions", "x1,x2", "--format", "json"], in: tempDir)

        let joined = result.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("\"event\""))
        XCTAssertTrue(joined.contains("complete"))
    }

    func testToleranceIsRecordedAndWidensTheResult() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // t2 differs from t1 at column 2, so that column qualifies only when a
        // single dissenting target is tolerated.
        let contents = """
        >t1
        AAAA
        >t2
        ACAA
        >x1
        GGGG

        """
        let bundleURL = try makeDiscriminatingSitesMSABundle(in: tempDir, contents: contents, name: "tolerance")
        let outputURL = tempDir.appendingPathComponent("tol.tsv")
        let command = try MSACommand.DiscriminatingSitesSubcommand.parse([
            bundleURL.path, "--exclusions", "x1",
            "--target-mismatch-tolerance", "1",
            "--output", outputURL.path,
        ])
        let recorder = DiscriminatingSitesLineRecorder()
        try command.executeForTesting { recorder.append($0) }

        XCTAssertTrue(recorder.lines().contains("Discriminating columns: 4"))
        let provenance = try provenanceDecoder().decode(
            MSADiscriminatingSitesProvenance.self,
            from: try Data(contentsOf: outputURL.appendingPathExtension("lungfish-provenance.json")))
        XCTAssertEqual(provenance.options.targetMismatchTolerance, 1)
    }

    func testRegistryDescribesTheActionAsCLIBacked() throws {
        let action = try XCTUnwrap(
            MultipleSequenceAlignmentActionRegistry.action(id: "msa.inspection.discriminating-sites"))
        XCTAssertTrue(action.requiresProvenance)
        XCTAssertEqual(action.cli?.command.contains("msa discriminating-sites"), true)
    }
}

private final class DiscriminatingSitesLineRecorder {
    private var storage: [String] = []
    func append(_ line: String) { storage.append(line) }
    func lines() -> [String] { storage }
}

private func makeDiscriminatingSitesMSABundle(
    in tempDir: URL, contents: String, name: String
) throws -> URL {
    let sourceURL = tempDir.appendingPathComponent("\(name).fasta")
    try contents.write(to: sourceURL, atomically: true, encoding: .utf8)
    let bundleURL = tempDir.appendingPathComponent("\(name).lungfishmsa", isDirectory: true)
    _ = try MultipleSequenceAlignmentBundle.importAlignment(
        from: sourceURL, to: bundleURL, options: .init(name: name))
    return bundleURL
}
