import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class CLIPreviewCommandTests: XCTestCase {
    func testLegacyFASTQImportPreviewUsesAvailableCLIImportCommand() {
        let sourceURL = URL(fileURLWithPath: "/Volumes/iWES WNPRC/reads/Sample R1.fastq.gz")
        let projectURL = URL(fileURLWithPath: "/Volumes/iWES WNPRC/Project.lungfish")

        let command = FASTQIngestionService.cliImportCommandPreview(
            sourceURL: sourceURL,
            projectDirectory: projectURL
        )

        XCTAssertTrue(command.hasPrefix("lungfish-cli import fastq "))
        XCTAssertTrue(command.contains("'/Volumes/iWES WNPRC/reads/Sample R1.fastq.gz'"))
        XCTAssertTrue(command.contains("--project '/Volumes/iWES WNPRC/Project.lungfish'"))
        XCTAssertTrue(command.contains("--format json"))
        XCTAssertTrue(command.contains("--quality-binning illumina4"))
        XCTAssertTrue(command.contains("--compression balanced"))
        XCTAssertFalse(command.contains("CLI command not yet available"))
        XCTAssertFalse(command.contains("use GUI"))
    }

    func testInPlaceFASTQIngestionPreviewUsesAvailableCLIImportCommand() {
        let sourceURL = URL(fileURLWithPath: "/Volumes/iWES WNPRC/downloads/Sample R1.fastq.gz")

        let command = FASTQIngestionService.inPlaceIngestionCommandPreview(url: sourceURL)

        XCTAssertTrue(command.hasPrefix("lungfish-cli import fastq "))
        XCTAssertTrue(command.contains("'/Volumes/iWES WNPRC/downloads/Sample R1.fastq.gz'"))
        XCTAssertTrue(command.contains("--project '/Volumes/iWES WNPRC/downloads'"))
        XCTAssertTrue(command.contains("--platform illumina"))
        XCTAssertFalse(command.contains("CLI command not yet available"))
        XCTAssertFalse(command.contains("use GUI"))
    }

    func testSPAdesConfigurationPreviewUsesManagedAssembleCommand() {
        let config = SPAdesAssemblyConfig(
            mode: .meta,
            forwardReads: [URL(fileURLWithPath: "/Volumes/Reads/Sample R1.fastq.gz")],
            reverseReads: [URL(fileURLWithPath: "/Volumes/Reads/Sample R2.fastq.gz")],
            memoryGB: 12,
            threads: 6,
            minContigLength: 700,
            skipErrorCorrection: true,
            covCutoff: "auto",
            phredOffset: 33,
            customArgs: ["--trusted-contigs", "/Volumes/Refs/trusted contigs.fa"],
            outputDirectory: URL(fileURLWithPath: "/Volumes/Assembly Output"),
            projectName: "Demo Assembly"
        )

        let command = AssemblyRunner.cliCommandPreview(config: config)

        XCTAssertTrue(command.hasPrefix("lungfish assemble "))
        XCTAssertTrue(command.contains("'/Volumes/Reads/Sample R1.fastq.gz'"))
        XCTAssertTrue(command.contains("'/Volumes/Reads/Sample R2.fastq.gz'"))
        XCTAssertTrue(command.contains("--paired"))
        XCTAssertTrue(command.contains("--assembler spades"))
        XCTAssertTrue(command.contains("--read-type illumina-short-reads"))
        XCTAssertTrue(command.contains("--project-name 'Demo Assembly'"))
        XCTAssertTrue(command.contains("--threads 6"))
        XCTAssertTrue(command.contains("--output '/Volumes/Assembly Output'"))
        XCTAssertTrue(command.contains("--memory-gb 12"))
        XCTAssertTrue(command.contains("--min-contig-length 700"))
        XCTAssertTrue(command.contains("--profile meta"))
        XCTAssertTrue(command.contains("--extra-args"))
        XCTAssertTrue(command.contains("--only-assembler"))
        XCTAssertTrue(command.contains("--cov-cutoff auto"))
        XCTAssertTrue(command.contains("--phred-offset 33"))
        XCTAssertTrue(command.contains("'/Volumes/Refs/trusted contigs.fa'"))
        XCTAssertFalse(command.contains("CLI command not yet available"))
    }
}
