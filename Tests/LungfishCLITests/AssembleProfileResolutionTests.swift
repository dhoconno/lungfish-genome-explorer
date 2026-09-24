import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class AssembleProfileResolutionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExplicitProfileWinsAndCarriesNoBasis() async throws {
        let url = try writeFASTQ(qualityCharacter: "(")
        let resolved = await AssembleCommand.resolveProfile(tool: .flye, explicitProfile: "nano-hq", inputURL: url)
        XCTAssertEqual(resolved.profileID, "nano-hq")
        XCTAssertNil(resolved.basis)
    }

    func testFlyeWithoutProfileAppliesTheReadQualityRule() async throws {
        let rawURL = try writeFASTQ(qualityCharacter: "(")
        let raw = await AssembleCommand.resolveProfile(tool: .flye, explicitProfile: nil, inputURL: rawURL)
        XCTAssertEqual(raw.profileID, "nano-raw")
        XCTAssertEqual(raw.basis, "nano-raw preselected from median read quality Q7 from the first 12 reads")

        let hqURL = try writeFASTQ(qualityCharacter: "-", name: "hq.fastq")
        let hq = await AssembleCommand.resolveProfile(tool: .flye, explicitProfile: nil, inputURL: hqURL)
        XCTAssertEqual(hq.profileID, "nano-hq")
        XCTAssertEqual(hq.basis, "nano-hq preselected from median read quality Q12 from the first 12 reads")
    }

    func testOtherAssemblersKeepTheirPipelineDefault() async throws {
        let url = try writeFASTQ(qualityCharacter: "(")
        let resolved = await AssembleCommand.resolveProfile(tool: .spades, explicitProfile: nil, inputURL: url)
        XCTAssertNil(resolved.profileID)
        XCTAssertNil(resolved.basis)
    }

    func testProvenanceRecordsTheResolvedProfileAndItsBasis() throws {
        let inputURL = try writeFASTQ(qualityCharacter: "(")
        let contigsURL = tempDir.appendingPathComponent("assembly.fasta")
        try ">contig_1\nACGTACGTACGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: .flye,
            readType: .ontReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "2.9.6",
            commandLine: "flye --nano-raw reads.fastq --out-dir out --threads 8",
            outputDirectory: tempDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 40
        )
        try result.save(to: tempDir)

        let basis = "nano-raw preselected from read quality Q8 from the bundle's statistics"
        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [inputURL],
            projectName: "demo",
            outputDirectory: tempDir,
            threads: 8,
            selectedProfileID: "nano-raw",
            profileSelectionBasis: basis
        )

        let sidecarURL = try AssembleCommand.writeProvenance(
            request: request,
            result: result,
            originalInputURLs: [inputURL],
            executionInputURLs: [inputURL],
            argv: ["lungfish-cli", "assemble", inputURL.path, "--assembler", "flye"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 140),
            writer: ProvenanceWriter(signingProvider: nil)
        )

        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["profile"], .string("nano-raw"))
        XCTAssertEqual(envelope.options.resolvedDefaults["profileBasis"], .string(basis))
    }

    private func writeFASTQ(qualityCharacter: Character, name: String = "reads.fastq") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var text = ""
        for index in 0..<12 {
            text += "@read\(index)\n\(String(repeating: "ACGT", count: 10))\n+\n\(String(repeating: qualityCharacter, count: 40))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
