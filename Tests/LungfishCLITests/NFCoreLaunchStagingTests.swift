import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class NFCoreLaunchStagingTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeRequest(
        input: URL,
        params: [String: String]
    ) throws -> NFCoreRunRequest {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        return NFCoreRunRequest(
            workflow: workflow,
            version: "3.0.0",
            executor: .docker,
            inputURLs: [input],
            outputDirectory: tempRoot.appendingPathComponent("My Results", isDirectory: true),
            expectedOutputURLs: [tempRoot.appendingPathComponent("My Results/consensus.lungfishref")],
            params: params
        )
    }

    func testStagesWhitespaceFilePathsIntoStagingRoot() throws {
        // The pipeline schema rejects any path with whitespace (^\S+\.csv$ and friends),
        // and a Lungfish project such as "My Genome Project.lungfish" puts every
        // bundle input under such a path.
        let project = tempRoot.appendingPathComponent("My Genome Project.lungfish/Analyses/run.lungfishrun/inputs", isDirectory: true)
        let samplesheet = try write("sample,fastq_1,fastq_2\nS1,/tmp/r1.fastq.gz,\n", to: project.appendingPathComponent("samplesheet.csv"))
        let bed = try write("MN908947.3\t30\t54\tp_LEFT\t1\t+\n", to: project.appendingPathComponent("primers/primers.bed"))
        let fasta = try write(">p_LEFT\nACGT\n", to: project.appendingPathComponent("primers/primers.fasta"))
        let request = try makeRequest(
            input: samplesheet,
            params: ["primer_bed": bed.path, "primer_fasta": fasta.path, "platform": "illumina"]
        )
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)

        let staged = try NFCoreLaunchStaging.stage(request, in: stagingRoot)

        let arguments = staged.nextflowArguments
        for flag in ["--input", "--primer_bed", "--primer_fasta"] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag), flag)
            let value = arguments[index + 1]
            XCTAssertNil(value.rangeOfCharacter(from: .whitespacesAndNewlines), "\(flag) still carries whitespace: \(value)")
            XCTAssertTrue(value.hasPrefix(stagingRoot.standardizedFileURL.path), value)
        }
        XCTAssertEqual(staged.inputURLs.first?.pathExtension, "csv")
        XCTAssertEqual(staged.params["primer_bed"].map { URL(fileURLWithPath: $0).pathExtension }, "bed")
        XCTAssertEqual(staged.params["primer_fasta"].map { URL(fileURLWithPath: $0).pathExtension }, "fasta")
        XCTAssertEqual(staged.params["platform"], "illumina")

        // Staged files are readable copies of the originals.
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(staged.inputURLs.first), encoding: .utf8), try String(contentsOf: samplesheet, encoding: .utf8))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: XCTUnwrap(staged.params["primer_bed"])), encoding: .utf8), try String(contentsOf: bed, encoding: .utf8))

        // Only the engine's view changes; the request's record-keeping fields do not.
        XCTAssertEqual(staged.outputDirectory, request.outputDirectory)
        XCTAssertEqual(staged.expectedOutputURLs, request.expectedOutputURLs)
        XCTAssertEqual(staged.version, request.version)
        XCTAssertEqual(staged.executor, request.executor)
        XCTAssertEqual(staged.presentationMode, request.presentationMode)
    }

    func testLeavesWhitespaceFreeRequestsUntouched() throws {
        let inputs = tempRoot.appendingPathComponent("plain/inputs", isDirectory: true)
        let samplesheet = try write("sample,fastq_1,fastq_2\n", to: inputs.appendingPathComponent("samplesheet.csv"))
        let bed = try write("x\n", to: inputs.appendingPathComponent("primers.bed"))
        let request = try makeRequest(input: samplesheet, params: ["primer_bed": bed.path, "platform": "illumina"])
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)

        let staged = try NFCoreLaunchStaging.stage(request, in: stagingRoot)

        XCTAssertEqual(staged, request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path), "No staging directory is created when nothing needs staging")
    }

    func testSanitizesBasenamesThatContainWhitespace() throws {
        let inputs = tempRoot.appendingPathComponent("plain", isDirectory: true)
        let samplesheet = try write("sample,fastq_1,fastq_2\n", to: inputs.appendingPathComponent("my samples.csv"))
        let request = try makeRequest(input: samplesheet, params: ["platform": "illumina"])
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)

        let staged = try NFCoreLaunchStaging.stage(request, in: stagingRoot)

        let stagedInput = try XCTUnwrap(staged.inputURLs.first)
        XCTAssertEqual(stagedInput.lastPathComponent, "my_samples.csv")
        XCTAssertNil(stagedInput.path.rangeOfCharacter(from: .whitespacesAndNewlines))
    }

    func testDirectoryValuedParametersAreLeftAlone() throws {
        let inputs = tempRoot.appendingPathComponent("plain", isDirectory: true)
        let samplesheet = try write("sample,fastq_1,fastq_2\n", to: inputs.appendingPathComponent("samplesheet.csv"))
        let fastqPass = tempRoot.appendingPathComponent("My Run/fastq_pass", isDirectory: true)
        try FileManager.default.createDirectory(at: fastqPass, withIntermediateDirectories: true)
        let request = try makeRequest(input: samplesheet, params: ["fastq_dir": fastqPass.path, "platform": "nanopore"])
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)

        let staged = try NFCoreLaunchStaging.stage(request, in: stagingRoot)

        XCTAssertEqual(staged.params["fastq_dir"], fastqPass.path)
    }

    func testStagingRootPrefersWhitespaceFreeScratch() throws {
        let scratch = tempRoot.appendingPathComponent("nfcore-run-abc", isDirectory: true)

        let root = try NFCoreLaunchStaging.stagingRoot(preferring: scratch)

        XCTAssertEqual(root.root, scratch.appendingPathComponent("inputs", isDirectory: true).standardizedFileURL)
        XCTAssertFalse(root.isFallback)
        // Nothing is created until an input actually needs staging.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.root.path))
    }

    func testStagingRootFallsBackToSystemTempWhenScratchContainsWhitespace() throws {
        // The launch scratch lives in the project's .tmp when the volume supports
        // Nextflow's cache, so "My Genome Project.lungfish/.tmp/nfcore-run-..."
        // is the normal case. Inputs must still be staged somewhere the schema accepts.
        let scratch = tempRoot.appendingPathComponent("My Genome Project.lungfish/.tmp/nfcore-run-abc", isDirectory: true)

        let root = try NFCoreLaunchStaging.stagingRoot(preferring: scratch)
        defer { try? FileManager.default.removeItem(at: root.root) }

        XCTAssertTrue(root.isFallback)
        XCTAssertNil(root.root.path.rangeOfCharacter(from: .whitespacesAndNewlines), root.root.path)
        XCTAssertFalse(root.root.path.hasPrefix(scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.root.path))
    }

    func testWorkDirectoryPrefersWhitespaceFreeScratch() throws {
        let scratch = tempRoot.appendingPathComponent("nfcore-run-abc", isDirectory: true)

        let work = try NFCoreLaunchStaging.workDirectory(preferring: scratch)

        XCTAssertEqual(work.root, scratch.appendingPathComponent("work", isDirectory: true).standardizedFileURL)
        XCTAssertFalse(work.isFallback)
    }

    func testWorkDirectoryFallsBackWhenScratchContainsWhitespace() throws {
        // QUAST refuses outright: "QUAST does not support spaces in paths."
        // Every task runs inside the Nextflow work tree, so a project named
        // "My Genome Project.lungfish" fails that step even though the staged
        // inputs were already moved off the whitespace path.
        let scratch = tempRoot.appendingPathComponent("My Genome Project.lungfish/.tmp/nfcore-run-abc", isDirectory: true)

        let work = try NFCoreLaunchStaging.workDirectory(preferring: scratch)
        defer { try? FileManager.default.removeItem(at: work.root) }

        XCTAssertTrue(work.isFallback)
        XCTAssertNil(work.root.path.rangeOfCharacter(from: .whitespacesAndNewlines), work.root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.root.path))
    }

    func testRejectsStagingRootThatContainsWhitespace() throws {
        let inputs = tempRoot.appendingPathComponent("My Inputs", isDirectory: true)
        let samplesheet = try write("sample,fastq_1,fastq_2\n", to: inputs.appendingPathComponent("samplesheet.csv"))
        let request = try makeRequest(input: samplesheet, params: [:])
        let stagingRoot = tempRoot.appendingPathComponent("bad stage", isDirectory: true)

        XCTAssertThrowsError(try NFCoreLaunchStaging.stage(request, in: stagingRoot))
    }
}
