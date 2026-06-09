import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqFullLengthONTMHCGenotypingCommandTests: XCTestCase {
    func testFullLengthONTMHCCommandParsesPBAAClusterSourceMode() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--guide", "/tmp/guide.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--pbaa-cluster-source", "require-existing",
        ])

        XCTAssertEqual(command.pbaaClusterSource, .requireExisting)
    }

    func testFullLengthONTMHCCommandParsesThreads() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--guide", "/tmp/guide.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--threads", "4",
        ])

        XCTAssertEqual(command.threads, 4)
    }

    func testFullLengthONTMHCCommandParsesThreadsThroughTopLevelCLI() throws {
        let parsed = try LungfishCLI.parseAsRoot([
            "fastq",
            "full-length-ont-mhc-genotype",
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--guide", "/tmp/guide.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--threads", "4",
        ])
        let command = try XCTUnwrap(parsed as? FastqFullLengthONTMHCGenotypingSubcommand)

        XCTAssertEqual(command.threads, 4)
    }

    func testFullLengthONTMHCRunRequestArgvIncludesPBAAClusterSourceMode() {
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq", isDirectory: true)],
            referenceSourceURL: URL(fileURLWithPath: "/tmp/ref.lungfishref", isDirectory: true),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.lungfishref", isDirectory: true),
            outputDirectory: URL(fileURLWithPath: "/tmp/out.lungfishgenotype", isDirectory: true),
            pbaaClusterSourceMode: .rerunAll
        )

        XCTAssertEqual(
            request.argv.suffix(2),
            ["--pbaa-cluster-source", "rerun-all"]
        )
    }
}
