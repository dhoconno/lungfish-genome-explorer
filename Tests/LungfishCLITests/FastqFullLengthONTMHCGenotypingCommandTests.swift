import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqFullLengthONTMHCGenotypingCommandTests: XCTestCase {
    func testFullLengthONTMHCCommandDoesNotRequireGuideSequences() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
            "--output-dir", "/tmp/out.lungfishgenotype",
        ])

        XCTAssertEqual(command.reference, "/tmp/ref.lungfishref")
    }

    func testFullLengthONTMHCCommandParsesThreads() throws {
        let command = try FastqFullLengthONTMHCGenotypingSubcommand.parse([
            "/tmp/sample.lungfishfastq",
            "--reference", "/tmp/ref.lungfishref",
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
            "--output-dir", "/tmp/out.lungfishgenotype",
            "--threads", "4",
        ])
        let command = try XCTUnwrap(parsed as? FastqFullLengthONTMHCGenotypingSubcommand)

        XCTAssertEqual(command.threads, 4)
    }

    func testFullLengthONTMHCRunRequestArgvUsesSavontAndOmitsGuideAndPBAAOptions() {
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq", isDirectory: true)],
            referenceSourceURL: URL(fileURLWithPath: "/tmp/ref.lungfishref", isDirectory: true),
            outputDirectory: URL(fileURLWithPath: "/tmp/out.lungfishgenotype", isDirectory: true)
        )

        XCTAssertFalse(request.argv.contains("--guide"))
        XCTAssertFalse(request.argv.contains { $0.contains("pbaa") || $0.contains("pbAA") })
        XCTAssertEqual(value(after: "--savont-quality-value-cutoff", in: request.argv), "90")
        XCTAssertEqual(value(after: "--savont-min-cluster-size", in: request.argv), "3")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
