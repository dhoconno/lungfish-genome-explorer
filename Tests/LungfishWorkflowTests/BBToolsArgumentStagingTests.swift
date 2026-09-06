import XCTest
@testable import LungfishWorkflow

/// Covers the shared staging that keeps every bbtools script usable for a
/// project whose path contains a space.
///
/// Regression context: all eight bbtools wrappers Lungfish invokes end with
/// `CMD="java ... $@"; eval $CMD`, so the shell re-splits every argument no
/// matter how carefully the caller built its argv array. A project named
/// "Amplicon genotyping results" made bbmerge die with "Unknown parameter
/// genotyping" before reading a single read.
final class BBToolsArgumentStagingTests: XCTestCase {

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCleanDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbtools-clean-\(UUID().uuidString)", isDirectory: true)
        try XCTSkipIf(
            BBToolsArgumentStaging.containsWhitespace(url.path),
            "System temp directory itself contains whitespace"
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func writeFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "@READ/1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Argument parsing

    func testSplitSeparatesOnTheFirstEqualsAndLowercasesTheKey() {
        let parsed = BBToolsArgumentStaging.split(argument: "In1=/tmp/a=b/x.fastq")
        XCTAssertEqual(parsed?.key, "in1")
        // A path may legitimately contain '=', so only the first one separates.
        XCTAssertEqual(parsed?.value, "/tmp/a=b/x.fastq")
    }

    func testSplitRejectsArgumentsThatAreNotKeyValue() {
        XCTAssertNil(BBToolsArgumentStaging.split(argument: "interleaved"))
        XCTAssertNil(BBToolsArgumentStaging.split(argument: "=/tmp/x"))
        XCTAssertNil(BBToolsArgumentStaging.split(argument: "out="))
    }

    // MARK: - Extension preservation

    /// bbtools infers format *and* codec from the filename. `URL.pathExtension`
    /// reduces `sample.fastq.gz` to `gz`, which tells the tool the bytes are
    /// gzipped but not that they are FASTQ; naming it `.fastq` instead makes
    /// bbmerge read compressed bytes as text and die inside its own parser.
    func testReadableSuffixKeepsBothFormatAndCodec() {
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "x.fastq.gz"), "fastq.gz")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "x.fq.gz"), "fq.gz")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "sample.R1.fastq.gz"), "fastq.gz")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "x.fastq"), "fastq")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "adapters.fa"), "fa")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "X.FASTQ.GZ"), "fastq.gz")
        XCTAssertEqual(BBToolsArgumentStaging.readableSuffix(of: "noextension"), "")
    }

    func testStagedNamesKeepTheReadableSuffix() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = try writeFile("WD1 S148.fastq.gz", in: working)

        let plan = try BBToolsArgumentStaging.plan(arguments: ["in=\(input.path)"])
        defer { plan.cleanUp() }

        let staged = try XCTUnwrap(plan.arguments.first)
        XCTAssertTrue(
            staged.hasSuffix(".fastq.gz"),
            "staged input lost its format suffix: \(staged)"
        )
    }

    // MARK: - Clean paths are untouched

    /// The whole point of gating on whitespace is that a project on a clean
    /// path keeps behaving exactly as it did before staging existed.
    func testCleanArgumentsArePassedThroughByteIdentically() throws {
        let clean = try makeCleanDirectory()
        let input = try writeFile("sample.fastq", in: clean)
        let arguments = [
            "in=\(input.path)",
            "out=\(clean.path)/merged.fastq",
            "interleaved=t",
            "threads=4",
        ]

        let plan = try BBToolsArgumentStaging.plan(arguments: arguments)
        defer { plan.cleanUp() }

        XCTAssertEqual(plan.arguments, arguments)
        XCTAssertFalse(plan.didStage)
        XCTAssertNil(plan.temporaryRoot)
    }

    func testACleanRunCreatesNoTemporaryDirectory() throws {
        let clean = try makeCleanDirectory()
        let input = try writeFile("sample.fastq", in: clean)
        var requestedTemporaryRoot = false
        let plan = try BBToolsArgumentStaging.plan(arguments: ["in=\(input.path)"]) {
            requestedTemporaryRoot = true
            throw CocoaError(.fileWriteUnknown)
        }
        defer { plan.cleanUp() }
        XCTAssertFalse(requestedTemporaryRoot, "A clean path must not request a staging directory")
        XCTAssertNil(plan.temporaryRoot)
    }

    /// Whitespace in a non-path argument is not a reason to stage: `threads=4`
    /// and flags never name a file.
    func testWhitespaceInANonPathParameterDoesNotTriggerStaging() throws {
        let plan = try BBToolsArgumentStaging.plan(
            arguments: ["in=/clean/x.fastq", "literal=a b c"]
        )
        defer { plan.cleanUp() }

        XCTAssertFalse(plan.didStage)
        XCTAssertEqual(plan.arguments, ["in=/clean/x.fastq", "literal=a b c"])
    }

    // MARK: - Staging a whitespace path

    func testStagedArgumentsContainNoWhitespace() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = try writeFile("WD1 S148 L001.fastq", in: working)
        let output = working.appendingPathComponent("merged out.fastq")

        let plan = try BBToolsArgumentStaging.plan(arguments: [
            "in=\(input.path)",
            "out=\(output.path)",
            "interleaved=t",
        ])
        defer { plan.cleanUp() }

        XCTAssertTrue(plan.didStage)
        for argument in plan.arguments {
            XCTAssertFalse(
                BBToolsArgumentStaging.containsWhitespace(argument),
                "argument would be re-split by the wrapper's eval: \(argument)"
            )
        }
        // Non-path arguments survive untouched.
        XCTAssertTrue(plan.arguments.contains("interleaved=t"))
    }

    func testStagedInputIsASymlinkNotACopy() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = try writeFile("WD1 S148.fastq", in: working)

        let plan = try BBToolsArgumentStaging.plan(arguments: ["in=\(input.path)"])
        defer { plan.cleanUp() }

        let stagedPath = String(try XCTUnwrap(plan.arguments.first).dropFirst("in=".count))
        // A copy would double the disk cost of a multi-gigabyte FASTQ.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: stagedPath)
        XCTAssertEqual(
            URL(fileURLWithPath: destination).standardizedFileURL.path,
            input.standardizedFileURL.path
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: stagedPath), encoding: .utf8),
            try String(contentsOf: input, encoding: .utf8)
        )
    }

    /// Outputs must not be symlinked: bbtools deletes and recreates its output
    /// files, which would replace the link with a regular file inside the
    /// staging root and leave the caller's path empty.
    func testStagedOutputIsNotPreCreated() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let output = working.appendingPathComponent("merged out.fastq")

        let plan = try BBToolsArgumentStaging.plan(arguments: ["out=\(output.path)"])
        defer { plan.cleanUp() }

        let stagedPath = String(try XCTUnwrap(plan.arguments.first).dropFirst("out=".count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))
    }

    func testTwoArgumentsWithTheSameLeafNameGetDistinctStagedPaths() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let first = try makeDirectory(named: "run one")
        let second = try makeDirectory(named: "run two")
        try writeFile("sample.fastq", in: first)
        try writeFile("sample.fastq", in: second)
        _ = working

        let plan = try BBToolsArgumentStaging.plan(arguments: [
            "in=\(first.path)/sample.fastq",
            "in2=\(second.path)/sample.fastq",
        ])
        defer { plan.cleanUp() }

        XCTAssertNotEqual(plan.arguments[0], plan.arguments[1])
    }

    // MARK: - Output adoption

    /// Losing an output silently is the worst failure mode this code can have,
    /// so adoption is asserted directly rather than inferred from a tool run.
    func testAdoptResultsMovesOutputsBackToTheCallersPath() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let output = working.appendingPathComponent("merged out.fastq")

        let plan = try BBToolsArgumentStaging.plan(arguments: ["out=\(output.path)"])
        let stagedPath = String(try XCTUnwrap(plan.arguments.first).dropFirst("out=".count))
        // Stand in for the tool writing its output.
        try "MERGED".write(toFile: stagedPath, atomically: true, encoding: .utf8)

        plan.adoptResults()
        plan.cleanUp()

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "MERGED")
    }

    func testAdoptResultsOverwritesAnExistingDestination() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let output = working.appendingPathComponent("merged out.fastq")
        try "STALE".write(to: output, atomically: true, encoding: .utf8)

        let plan = try BBToolsArgumentStaging.plan(arguments: ["out=\(output.path)"])
        let stagedPath = String(try XCTUnwrap(plan.arguments.first).dropFirst("out=".count))
        try "FRESH".write(toFile: stagedPath, atomically: true, encoding: .utf8)

        plan.adoptResults()
        plan.cleanUp()

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "FRESH")
    }

    /// A missing staged output is normal, not an error: bbmerge writes no
    /// `outu` stream when every pair merged, bbduk no `outm` when nothing
    /// matched. Adoption must skip what was never created.
    func testAdoptResultsSkipsOutputsTheToolNeverWrote() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let merged = working.appendingPathComponent("merged out.fastq")
        let unmerged = working.appendingPathComponent("unmerged out.fastq")

        let plan = try BBToolsArgumentStaging.plan(arguments: [
            "out=\(merged.path)",
            "outu=\(unmerged.path)",
        ])
        let mergedStaged = String(try XCTUnwrap(plan.arguments.first).dropFirst("out=".count))
        try "MERGED".write(toFile: mergedStaged, atomically: true, encoding: .utf8)

        plan.adoptResults()
        plan.cleanUp()

        XCTAssertEqual(try String(contentsOf: merged, encoding: .utf8), "MERGED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unmerged.path))
    }

    func testAdoptResultsIsANoOpForACleanRun() throws {
        let clean = try makeCleanDirectory()
        let output = clean.appendingPathComponent("merged.fastq")
        let plan = try BBToolsArgumentStaging.plan(arguments: ["out=\(output.path)"])

        // Nothing was rewritten, so the tool wrote straight to the real path.
        try "MERGED".write(to: output, atomically: true, encoding: .utf8)
        plan.adoptResults()
        plan.cleanUp()

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "MERGED")
    }

    // MARK: - Cleanup

    func testCleanUpRemovesTheStagingRoot() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = try writeFile("WD1 S148.fastq", in: working)

        let plan = try BBToolsArgumentStaging.plan(arguments: ["in=\(input.path)"])
        let root = try XCTUnwrap(plan.temporaryRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        plan.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // The linked input is untouched: only the link was removed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    /// The error path must clean up too, which is why the runner defers
    /// `cleanUp()` rather than calling it after a successful exit.
    func testCleanUpAfterAFailedRunLeavesNoStagingRootBehind() throws {
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = try writeFile("WD1 S148.fastq", in: working)
        let output = working.appendingPathComponent("merged out.fastq")

        let root: URL
        do {
            let plan = try BBToolsArgumentStaging.plan(arguments: [
                "in=\(input.path)",
                "out=\(output.path)",
            ])
            defer { plan.cleanUp() }
            root = try XCTUnwrap(plan.temporaryRoot)
            // Simulate the tool failing before it wrote anything.
            plan.adoptResults()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Tool classification

    func testEveryBBToolsWrapperIsClassifiedAsAShellScript() {
        // All eight ship the `eval $CMD` tail, so all eight need staging.
        let wrappers: [NativeTool] = [
            .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio,
        ]
        for tool in wrappers {
            XCTAssertTrue(
                tool.isBBToolsShellScript,
                "\(tool.rawValue) ships an eval-based wrapper and must be staged"
            )
        }
    }

    func testNonBBToolsAreNotStaged() {
        // Staging rewrites paths, so it must not touch tools that quote argv
        // correctly and would be handed a path their caller does not expect.
        for tool in [NativeTool.samtools, .cutadapt, .seqkit, .fastp, .vsearch] {
            XCTAssertFalse(tool.isBBToolsShellScript)
        }
    }

    // MARK: - End to end through the runner

    /// Skips unless the managed bbtools environment is installed, matching the
    /// suite's other conda-dependent tests.
    private func requireBBTools() throws {
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/bbtools/bin/reformat.sh")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("bbtools conda environment is not installed")
        }
    }

    /// The whole point: a real bbtools script, launched by the real runner, on
    /// the kind of path a user's project actually has.
    func testReformatRunsAndWritesOutputOnASpacedPath() async throws {
        try requireBBTools()
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let input = working.appendingPathComponent("WD1 S148 L001.fastq")
        try Self.fastqText().write(to: input, atomically: true, encoding: .utf8)
        let output = working.appendingPathComponent("converted out.fasta")

        let result = try await NativeToolRunner.shared.run(
            .reformat,
            arguments: [
                "in=\(input.path)",
                "out=\(output.path)",
                "ow=t",
            ],
            timeout: 300
        )

        XCTAssertFalse(
            result.stderr.contains("Unknown parameter"),
            "the wrapper re-split an argument: \(result.stderr)"
        )
        XCTAssertTrue(result.isSuccess, "reformat.sh failed: \(result.stderr)")
        // Output adoption is the part that silently loses results when wrong.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: output.path),
            "output was never moved back out of staging"
        )
        let produced = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(produced.hasPrefix(">"), "expected FASTA, got: \(produced.prefix(80))")
        XCTAssertEqual(produced.filter { $0 == ">" }.count, 4)
    }

    /// A gzipped input must keep `.fastq.gz` when staged. Truncating it to
    /// `.gz` or `.fastq` makes bbtools misread the stream rather than fail
    /// loudly, so this asserts on the decoded content.
    func testGzippedInputOnASpacedPathIsReadCorrectly() async throws {
        try requireBBTools()
        let working = try makeDirectory(named: "Amplicon genotyping results")
        let plain = working.appendingPathComponent("WD1 S148.fastq")
        try Self.fastqText().write(to: plain, atomically: true, encoding: .utf8)

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        let gzipped = working.appendingPathComponent("WD1 S148.fastq.gz")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: gzipped.path),
            "gzip did not produce the compressed fixture"
        )
        let output = working.appendingPathComponent("converted out.fasta")

        let result = try await NativeToolRunner.shared.run(
            .reformat,
            arguments: ["in=\(gzipped.path)", "out=\(output.path)", "ow=t"],
            timeout: 300
        )

        XCTAssertTrue(result.isSuccess, "reformat.sh failed: \(result.stderr)")
        let produced = try String(contentsOf: output, encoding: .utf8)
        // Reading compressed bytes as text yields garbage, not four records.
        XCTAssertEqual(produced.filter { $0 == ">" }.count, 4)
        XCTAssertTrue(produced.contains("ACGTTGCAAGGCTTACCGGTTACAGGATCC"))
    }

    /// A clean path must reach the tool byte-identically, with no staging.
    func testReformatOnACleanPathIsUnaffected() async throws {
        try requireBBTools()
        let clean = try makeCleanDirectory()
        let input = clean.appendingPathComponent("sample.fastq")
        try Self.fastqText().write(to: input, atomically: true, encoding: .utf8)
        let output = clean.appendingPathComponent("converted.fasta")

        let result = try await NativeToolRunner.shared.run(
            .reformat,
            arguments: ["in=\(input.path)", "out=\(output.path)", "ow=t"],
            timeout: 300
        )

        XCTAssertTrue(result.isSuccess, "reformat.sh failed: \(result.stderr)")
        // The tool was handed the caller's own paths, not staged ones.
        XCTAssertTrue(result.arguments.contains("in=\(input.path)"))
        XCTAssertTrue(result.arguments.contains("out=\(output.path)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private static func fastqText() -> String {
        let sequence = "ACGTTGCAAGGCTTACCGGTTACAGGATCCATTGCAACGTTGCAAGGCTTACCGGTTACA"
        var text = ""
        for index in 0..<4 {
            text += "@READ\(index)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        return text
    }
}
