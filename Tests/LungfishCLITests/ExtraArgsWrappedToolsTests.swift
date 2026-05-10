import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class ExtraArgsWrappedToolsTests: XCTestCase {
    func testOrientExtraArgsParseAndReachVsearchArguments() throws {
        let command = try OrientCommand.parse([
            "reads.fastq",
            "--reference", "reference.fasta",
            "--extra-args", "--id 0.97 --strand both",
        ])

        let config = try command.makeConfigForTesting()
        let arguments = config.vsearchArgumentsForTesting(
            orientedOutput: URL(fileURLWithPath: "/tmp/oriented.fastq"),
            tabbedOutput: URL(fileURLWithPath: "/tmp/orient.tsv"),
            unmatchedOutput: nil
        )

        XCTAssertEqual(config.extraArguments, ["--id", "0.97", "--strand", "both"])
        XCTAssertTrue(arguments.suffix(4).elementsEqual(["--id", "0.97", "--strand", "both"]))
    }

    func testBlastExtraArgsParseAndReachVerificationRequest() throws {
        let command = try BlastCommand.VerifySubcommand.parse([
            "--kreport", "classification.kreport",
            "--source", "reads.fastq",
            "--kraken-output", "classification.kraken",
            "--taxid", "562",
            "--extra-args", "MEGABLAST=off WORD_SIZE=11",
        ])

        let request = try command.makeVerificationRequestForTesting(
            taxonName: "Escherichia coli",
            sequences: [("read1", "ACGT")]
        )

        XCTAssertEqual(request.extraArgs, "MEGABLAST=off WORD_SIZE=11")
    }

    func testEsVirituExtraArgsParseAndReachCommandArguments() throws {
        let command = try EsVirituCommand.DetectSubcommand.parse([
            "detect",
            "--input", "reads.fastq",
            "--sample", "sample-a",
            "--db", "/db/esviritu",
            "--extra-args", "--min_ani 0.95 --keep_tmp",
        ])

        let config = try command.makeConfigForTesting(
            databaseURL: URL(fileURLWithPath: "/db/esviritu"),
            outputDirectory: URL(fileURLWithPath: "/tmp/esviritu")
        )

        XCTAssertEqual(config.extraArguments, ["--min_ani", "0.95", "--keep_tmp"])
        XCTAssertTrue(config.esVirituArguments().suffix(3).elementsEqual(["--min_ani", "0.95", "--keep_tmp"]))
    }

    func testTaxTriageExtraArgsParseAndReachNextflowArguments() throws {
        let command = try TaxTriageCommand.RunSubcommand.parse([
            "run",
            "--input", "reads.fastq",
            "--sample", "sample-a",
            "--output", "/tmp/taxtriage",
            "--extra-args", "--skip_fastqc --custom_config_base /configs",
        ])

        let config = try command.makeConfigForTesting()

        XCTAssertEqual(config.extraArguments, ["--skip_fastqc", "--custom_config_base", "/configs"])
        XCTAssertTrue(config.nextflowArguments().suffix(3).elementsEqual(["--skip_fastqc", "--custom_config_base", "/configs"]))
    }

    func testTreeInferExtraArgsParseAndReachIQTreeArguments() async throws {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/ExtraArgsTreeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let msaSourceURL = tempDir.appendingPathComponent("input.aligned.fasta")
        try ">A\nACGT\n>B\nACGA\n".write(to: msaSourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: msaSourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )
        let fakeIQTreeURL = try writeFakeIQTreeExecutable(in: tempDir)
        let outputURL = projectURL.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        let command = try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", outputURL.path,
            "--iqtree-path", fakeIQTreeURL.path,
            "--extra-args", "-bnni --pathogen",
        ])

        try await command.executeForTesting { _ in }

        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        let options = try XCTUnwrap(provenanceJSON["options"] as? [String: String])
        XCTAssertEqual(options["extraArgs"], "-bnni --pathogen")
        let externalTool = try XCTUnwrap(provenanceJSON["externalTool"] as? [String: Any])
        let externalArguments = try XCTUnwrap(externalTool["arguments"] as? [String])
        XCTAssertTrue(externalArguments.contains("-bnni"))
        XCTAssertTrue(externalArguments.contains("--pathogen"))
    }

    func testAlignExtraArgsParseAndReachMAFFTRequest() throws {
        let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
        let input = project.appendingPathComponent("input.fasta")
        let command = try AlignCommand.MAFFTSubcommand.parse([
            "mafft",
            input.path,
            "--project", project.path,
            "--extra-args", "--op 1.53 --leavegappyregion",
        ])

        let request = try command.makeRequestForTesting()

        XCTAssertEqual(request.extraArguments, ["--op", "1.53", "--leavegappyregion"])
        XCTAssertTrue(request.wrapperArgv.contains("--extra-args"))
    }

    func testFastqTrimExtraArgsParseAndReachFastpArguments() throws {
        let command = try FastqQualityTrimSubcommand.parse([
            "reads.fastq",
            "--output", "trimmed.fastq",
            "--extra-args", "--cut_mean_quality 25 --length_required 75",
        ])

        let arguments = try command.fastpArgumentsForTesting(inputURL: URL(fileURLWithPath: "/tmp/reads.fastq"))

        XCTAssertEqual(command.extraArguments, ["--cut_mean_quality", "25", "--length_required", "75"])
        XCTAssertTrue(arguments.suffix(4).elementsEqual(["--cut_mean_quality", "25", "--length_required", "75"]))
    }

    func testCondaClassifyExtraArgsParseAndReachKraken2Arguments() throws {
        let command = try ClassifyCommand.parse([
            "reads.fastq",
            "--db", "Viral",
            "--extra-args", "--minimum-base-quality 20 --use-names",
        ])

        let config = try command.makeConfigForTesting(
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            databasePath: URL(fileURLWithPath: "/db/kraken2"),
            inputFormat: .fastq,
            outputDirectory: URL(fileURLWithPath: "/tmp/classification")
        )

        XCTAssertEqual(config.extraArguments, ["--minimum-base-quality", "20", "--use-names"])
        XCTAssertTrue(config.kraken2Arguments().contains("--minimum-base-quality"))
        XCTAssertTrue(config.kraken2Arguments().contains("--use-names"))
    }

    func testMSARunRequestPreservesExtraArgsForProvenanceReadySurface() throws {
        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [URL(fileURLWithPath: "/tmp/input.fasta")],
            projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
            outputBundleURL: URL(fileURLWithPath: "/tmp/Project.lungfish/Aligned.lungfishmsa"),
            name: "Aligned",
            threads: nil,
            extraArguments: ["--op", "1.53"],
            wrapperArgv: ["lungfish", "msa", "run", "/tmp/input.fasta", "--extra-args", "--op 1.53"]
        )

        XCTAssertEqual(request.extraArguments, ["--op", "1.53"])
        XCTAssertTrue(request.wrapperArgv.contains("--extra-args"))
    }
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeFakeIQTreeExecutable(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("iqtree3")
    try """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "IQ-TREE multicore version 3.1.1"
      exit 0
    fi
    prefix=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --prefix)
          prefix="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    echo "(A:0.1,B:0.2);" > "$prefix.treefile"
    echo "fake iqtree stdout"
    echo "fake iqtree stderr" >&2
    exit 0
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
