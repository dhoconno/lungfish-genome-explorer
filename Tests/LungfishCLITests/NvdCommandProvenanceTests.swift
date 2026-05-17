import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class NvdCommandProvenanceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NvdCommandProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testImportWritesCanonicalProvenanceForFinalManifest() async throws {
        let nvdDir = try makeNvdRunDirectory()
        let outputDir = tempDir.appendingPathComponent("imports", isDirectory: true)
        let command = try NvdCommand.ImportSubcommand.parse([
            nvdDir.path,
            "--output-dir", outputDir.path,
            "--name", "ImportedNVD",
            "--quiet",
        ])

        try await command.run()

        let bundleDir = outputDir.appendingPathComponent("ImportedNVD", isDirectory: true)
        let csvURL = nvdDir
            .appendingPathComponent("05_labkey_bundling", isDirectory: true)
            .appendingPathComponent("sample_blast_concatenated.csv")
        let manifestURL = bundleDir.appendingPathComponent("manifest.json")
        let provenanceURL = bundleDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleDir))
        let step = try XCTUnwrap(envelope.steps.first)
        let input = try XCTUnwrap(step.inputs.first { pathsMatch($0.path, csvURL) })
        let output = try XCTUnwrap(step.outputs.first { pathsMatch($0.path, manifestURL) })

        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertEqual(envelope.workflowName, "lungfish nvd import")
        XCTAssertEqual(envelope.toolName, "lungfish nvd import")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertNotNil(envelope.wallTimeSeconds)
        XCTAssertEqual(envelope.options.explicit["inputPath"]?.stringValue, nvdDir.path)
        XCTAssertEqual(envelope.options.resolvedDefaults["outputDir"]?.stringValue, outputDir.path)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "nvd", "import", nvdDir.path,
            "--output-dir", outputDir.path,
            "--name", "ImportedNVD",
        ])
        XCTAssertEqual(input.role, .input)
        XCTAssertEqual(input.format, .unknown)
        XCTAssertNotNil(input.checksumSHA256)
        XCTAssertGreaterThan(input.fileSize ?? 0, 0)
        XCTAssertEqual(output.role, .output)
        XCTAssertEqual(output.format, .json)
        XCTAssertNotNil(output.checksumSHA256)
        XCTAssertGreaterThan(output.fileSize ?? 0, 0)
        XCTAssertTrue(envelope.reproducibleCommand.contains("lungfish nvd import"))
    }

    private func makeNvdRunDirectory() throws -> URL {
        let nvdDir = tempDir.appendingPathComponent("nvd-run", isDirectory: true)
        let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
        let csvURL = labkeyDir.appendingPathComponent("sample_blast_concatenated.csv")
        try nvdCSV.write(to: csvURL, atomically: true, encoding: .utf8)
        return nvdDir
    }

    private var nvdCSV: String {
        """
        experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
        EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species

        """
    }

    private func pathsMatch(_ recordedPath: String, _ url: URL) -> Bool {
        normalizedPath(recordedPath) == normalizedPath(url.path)
    }

    private func normalizedPath(_ path: String) -> String {
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
