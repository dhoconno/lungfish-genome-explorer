import XCTest
@testable import LungfishWorkflow

final class ManagedAssemblyPipelineTests: XCTestCase {
    private func makeHifiasmRequest(
        readType: AssemblyReadType,
        selectedProfileID: String?,
        extraArguments: [String] = []
    ) -> AssemblyRunRequest {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-hifiasm-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return AssemblyRunRequest(
            tool: .hifiasm,
            readType: readType,
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq.gz")],
            projectName: "demo",
            outputDirectory: tempDir,
            threads: 8,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }

    func testBuildsSpadesCommandForIlluminaReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-spades-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "ecoli",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 8,
            memoryGB: 16,
            minContigLength: 500,
            selectedProfileID: "isolate",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "spades.py")
        XCTAssertEqual(command.environment, "spades")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--isolate"))
        XCTAssertTrue(command.arguments.contains("--threads"))
        XCTAssertTrue(command.arguments.contains("--memory"))
        XCTAssertTrue(command.arguments.contains("-1"))
        XCTAssertTrue(command.arguments.contains("-2"))
    }

    func testBuildsFlyeCommandForOntReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-flye-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/ont.fastq.gz")],
            projectName: "ont-demo",
            outputDirectory: tempDir,
            threads: 16,
            memoryGB: nil,
            minContigLength: nil,
            selectedProfileID: "nano-hq",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "flye")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--nano-hq"))
        XCTAssertTrue(command.arguments.contains("--out-dir"))
    }

    func testBuildsHifiasmCommandForOntReadsIncludesOntFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-hifiasm-ont-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = URL(fileURLWithPath: "/tmp/ont.fastq.gz")
        let request = AssemblyRunRequest(
            tool: .hifiasm,
            readType: .ontReads,
            inputURLs: [inputURL],
            projectName: "ont-demo",
            outputDirectory: tempDir,
            threads: 8,
            extraArguments: ["--verbosity", "2"]
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "hifiasm")
        XCTAssertEqual(command.environment, "hifiasm")
        XCTAssertEqual(command.workingDirectory, tempDir)
        XCTAssertEqual(command.arguments.filter { $0 == "--ont" }.count, 1)
        XCTAssertEqual(command.arguments.last, "2")
        XCTAssertTrue(command.arguments.contains(inputURL.path))
        XCTAssertEqual(command.arguments.filter { $0 == inputURL.path }.count, 1)
    }

    func testBuildsHifiasmCommandForOntDiploidOmitsHaploidFlags() throws {
        let request = makeHifiasmRequest(readType: .ontReads, selectedProfileID: "diploid")

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "hifiasm")
        XCTAssertTrue(command.arguments.contains("--ont"))
        XCTAssertFalse(command.arguments.contains("--n-hap"))
        XCTAssertFalse(command.arguments.contains("-l0"))
        XCTAssertFalse(command.arguments.contains("-f0"))
    }

    func testBuildsHifiasmCommandForOntHaploidViralIncludesCuratedFlags() throws {
        let request = makeHifiasmRequest(readType: .ontReads, selectedProfileID: "haploid-viral")

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertTrue(command.arguments.contains("--ont"))
        XCTAssertEqual(command.arguments.filter { $0 == "--n-hap" }.count, 1)
        XCTAssertEqual(command.arguments.filter { $0 == "1" }.count, 1)
        XCTAssertTrue(command.arguments.contains("-l0"))
        XCTAssertTrue(command.arguments.contains("-f0"))
    }

    func testBuildsHifiasmCommandForPacBioHiFiHaploidViralOmitsOntFlag() throws {
        let request = makeHifiasmRequest(readType: .pacBioHiFi, selectedProfileID: "haploid-viral")

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertFalse(command.arguments.contains("--ont"))
        XCTAssertEqual(command.arguments.filter { $0 == "--n-hap" }.count, 1)
        XCTAssertTrue(command.arguments.contains("-l0"))
        XCTAssertTrue(command.arguments.contains("-f0"))
    }

    func testBuildsHifiasmCommandPrimaryToggleRemainsIndependentOfProfileSelection() throws {
        let request = makeHifiasmRequest(
            readType: .pacBioHiFi,
            selectedProfileID: "diploid",
            extraArguments: ["--primary"]
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertTrue(command.arguments.contains("--primary"))
        XCTAssertFalse(command.arguments.contains("--ont"))
        XCTAssertFalse(command.arguments.contains("--n-hap"))
    }

    func testBuildsMegahitCommandForShortReads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-megahit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "meta-demo",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 12,
            memoryGB: nil,
            minContigLength: 1000,
            selectedProfileID: "meta-sensitive",
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.executable, "megahit")
        XCTAssertEqual(command.workingDirectory, tempDir.deletingLastPathComponent())
        XCTAssertTrue(command.arguments.contains("--num-cpu-threads"))
        XCTAssertTrue(command.arguments.contains("--presets"))
        XCTAssertTrue(command.arguments.contains("--min-contig-len"))
    }

    func testBuildsMegahitCommandConvertsMemoryBudgetToBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-megahit-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "memory-demo",
            outputDirectory: tempDir,
            threads: 8,
            memoryGB: 24,
            minContigLength: 1000,
            selectedProfileID: nil,
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        let memoryIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--memory"))
        XCTAssertEqual(command.arguments[memoryIndex + 1], "25769803776")
    }

    #if os(macOS) && arch(arm64)
    func testBuildsMegahitCommandCapsThreadsToTwoOnAppleSilicon() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-megahit-threads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "thread-demo",
            outputDirectory: tempDir,
            threads: 8,
            memoryGB: nil,
            minContigLength: 1000,
            selectedProfileID: nil,
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        let threadIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--num-cpu-threads"))
        XCTAssertEqual(command.arguments[threadIndex + 1], "2")
    }
    #endif

    func testBuildsSkesaCommandNormalizesZeroMinContigLengthToOne() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-skesa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .skesa,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "skesa-demo",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 8,
            memoryGB: nil,
            minContigLength: 0,
            selectedProfileID: nil,
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        let minContigIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--min_contig"))
        XCTAssertEqual(command.arguments[minContigIndex + 1], "1")
    }

    func testBuildsSkesaCommandPinsMinCountToTwoWhenUnspecified() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-skesa-min-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .skesa,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "skesa-demo",
            outputDirectory: tempDir,
            threads: 8,
            memoryGB: 32,
            minContigLength: 1,
            selectedProfileID: nil,
            extraArguments: []
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        let minCountIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--min_count"))
        XCTAssertEqual(command.arguments[minCountIndex + 1], "2")
    }

    func testBuildsSkesaCommandDoesNotDuplicateExplicitMinCountOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-skesa-explicit-min-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .skesa,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "skesa-demo",
            outputDirectory: tempDir,
            threads: 8,
            memoryGB: 32,
            minContigLength: 1,
            selectedProfileID: nil,
            extraArguments: ["--min_count", "5"]
        )

        let command = try ManagedAssemblyPipeline.buildCommand(for: request)

        XCTAssertEqual(command.arguments.filter { $0 == "--min_count" }.count, 1)
        let minCountIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--min_count"))
        XCTAssertEqual(command.arguments[minCountIndex + 1], "5")
    }

    func testRunStagesMegahitIntoFreshWorkspaceWhenFinalOutputDirectoryAlreadyExists() async throws {
        let tempRoot = try makeTempDirectory(prefix: "managed assembly megahit")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledMicromamba = tempRoot.appendingPathComponent("bundled-micromamba")
        let argsLog = tempRoot.appendingPathComponent("megahit-args.log")
        try writeExecutableScript(
            at: bundledMicromamba,
            body: megahitMicromambaScript(argsLog: argsLog)
        )

        let pipeline = ManagedAssemblyPipeline(
            condaManager: CondaManager(
                rootPrefix: tempRoot.appendingPathComponent("conda-root", isDirectory: true),
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        )

        let input1 = tempRoot.appendingPathComponent("R1.fastq.gz")
        let input2 = tempRoot.appendingPathComponent("R2.fastq.gz")
        try Data("ACGT".utf8).write(to: input1)
        try Data("TGCA".utf8).write(to: input2)

        let outputDir = tempRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("megahit-2026-04-19T18-54-52", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [input1, input2],
            projectName: "megahit-demo",
            outputDirectory: outputDir,
            pairedEnd: true,
            threads: 4
        )

        let result = try await pipeline.run(request: request)

        XCTAssertEqual(
            result.contigsPath.standardizedFileURL,
            outputDir.appendingPathComponent("final.contigs.fa").standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("assembly-result.json").path))

        let args = try String(contentsOf: argsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let outputIndex = try XCTUnwrap(args.firstIndex(of: "-o"))
        XCTAssertNotEqual(args[outputIndex + 1], outputDir.path)
        XCTAssertTrue(args[outputIndex + 1].contains("managed-assembly-"))
    }

    func testRejectsIncompatibleToolReadType() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
            projectName: "bad-demo",
            outputDirectory: tempDir,
            threads: 8
        )

        XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: request)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Flye is not available for Illumina short reads in v1."
            )
        }
    }

    func testHifiasmTopologyErrorUsesCombinedONTAndHiFiLabel() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-assembly-hifiasm-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .hifiasm,
            readType: .pacBioHiFi,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/sample-1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/sample-2.fastq.gz"),
            ],
            projectName: "bad-hifiasm-demo",
            outputDirectory: tempDir,
            threads: 8
        )

        XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: request)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Hifiasm expects a single ONT or PacBio HiFi/CCS FASTQ input in v1."
            )
        }
    }

    func testRunStagesSpaceSensitiveSpadesPathsThroughSpaceFreeWorkspace() async throws {
        let tempRoot = try makeTempDirectory(prefix: "managed assembly space")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledMicromamba = tempRoot.appendingPathComponent("bundled-micromamba")
        let argsLog = tempRoot.appendingPathComponent("spades-args.log")
        try writeExecutableScript(
            at: bundledMicromamba,
            body: micromambaScript(argsLog: argsLog, shouldFail: false)
        )

        let pipeline = ManagedAssemblyPipeline(
            condaManager: CondaManager(
                rootPrefix: tempRoot.appendingPathComponent("conda-root", isDirectory: true),
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        )

        let projectURL = tempRoot.appendingPathComponent("Project With Spaces.lungfish", isDirectory: true)
        let inputDir = projectURL.appendingPathComponent("Input Reads", isDirectory: true)
        let outputDir = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("spades output", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let inputURL = inputDir.appendingPathComponent("reads.fastq.gz")
        try Data("ACGT".utf8).write(to: inputURL)

        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [inputURL],
            projectName: "space-demo",
            outputDirectory: outputDir,
            threads: 4
        )

        let result = try await pipeline.run(request: request)

        XCTAssertEqual(result.contigsPath.standardizedFileURL, outputDir.appendingPathComponent("contigs.fasta").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("assembly-result.json").path))

        let args = try String(contentsOf: argsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let inputIndex = try XCTUnwrap(args.firstIndex(of: "-s"))
        let outputIndex = try XCTUnwrap(args.firstIndex(of: "-o"))
        XCTAssertFalse(args[inputIndex + 1].contains(" "), "Expected staged input path to be space-free")
        XCTAssertFalse(args[outputIndex + 1].contains(" "), "Expected staged output path to be space-free")
        XCTAssertTrue(args[outputIndex + 1].contains("managed-assembly-"))
    }

    func testRunThrowsExecutionFailedForNonZeroAssemblerExit() async throws {
        let tempRoot = try makeTempDirectory(prefix: "managed assembly failure")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledMicromamba = tempRoot.appendingPathComponent("bundled-micromamba")
        try writeExecutableScript(
            at: bundledMicromamba,
            body: micromambaScript(shouldFail: true)
        )

        let pipeline = ManagedAssemblyPipeline(
            condaManager: CondaManager(
                rootPrefix: tempRoot.appendingPathComponent("conda-root", isDirectory: true),
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        )

        let outputDir = tempRoot.appendingPathComponent("output", isDirectory: true)
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "failure-demo",
            outputDirectory: outputDir,
            threads: 4
        )

        do {
            _ = try await pipeline.run(request: request)
            XCTFail("Expected managed assembly to throw on non-zero exit")
        } catch let error as ManagedAssemblyPipelineError {
            guard case .executionFailed(let tool, let exitCode, let detail) = error else {
                XCTFail("Expected executionFailed error, got \(error)")
                return
            }
            XCTAssertEqual(tool, "SPAdes")
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(detail.contains("Exception caught conversion of data to type"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("assembly.log").path))
        }
    }

    func testRunPrefersSpecificSpadesLogErrorOverGenericAbnormalExitLine() async throws {
        let tempRoot = try makeTempDirectory(prefix: "managed assembly spades log failure")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundledMicromamba = tempRoot.appendingPathComponent("bundled-micromamba")
        try writeExecutableScript(
            at: bundledMicromamba,
            body: micromambaScript(
                shouldFail: true,
                spadesLogBody: """
                0:00:00.690 ERROR General Invalid kmer coverage histogram, make sure that the coverage is indeed uniform
                == Error == system call for: \"['spades-core']\" finished abnormally, OS return value: 255
                """
            )
        )

        let pipeline = ManagedAssemblyPipeline(
            condaManager: CondaManager(
                rootPrefix: tempRoot.appendingPathComponent("conda-root", isDirectory: true),
                bundledMicromambaProvider: { bundledMicromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        )

        let outputDir = tempRoot.appendingPathComponent("output", isDirectory: true)
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            projectName: "spades-log-detail-demo",
            outputDirectory: outputDir,
            threads: 4
        )

        do {
            _ = try await pipeline.run(request: request)
            XCTFail("Expected managed assembly to throw on non-zero exit")
        } catch let error as ManagedAssemblyPipelineError {
            guard case .executionFailed(_, _, let detail) = error else {
                XCTFail("Expected executionFailed error, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("Invalid kmer coverage histogram"))
            XCTAssertFalse(detail.contains("finished abnormally"))
        }
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutableScript(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func micromambaScript(
        argsLog: URL? = nil,
        shouldFail: Bool,
        spadesLogBody: String? = nil
    ) -> String {
        let argsLogPath = argsLog?.path ?? "/dev/null"
        let spadesLogSection: String
        if let spadesLogBody, !spadesLogBody.isEmpty {
            spadesLogSection = """
            cat <<'EOF' > "$outdir/spades.log"
            \(spadesLogBody)
            EOF
            """
        } else {
            spadesLogSection = ""
        }
        let failureBody = shouldFail
            ? """
            mkdir -p "$outdir"
            \(spadesLogSection)
            printf '%s\n' 'Exception caught conversion of data to type "std::__fs::filesystem::path" failed' >&2
            exit 1
            """
            : """
            printf '>contig1\nACGT\n' > "$outdir/contigs.fasta"
            printf '%s\n' 'SPAdes pipeline finished' > "$outdir/spades.log"
            exit 0
            """

        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf '%s\n' '2.0.0'
            exit 0
        fi

        if [ "$1" != "run" ] || [ "$2" != "-n" ]; then
            printf '%s\n' "unexpected micromamba invocation: $*" >&2
            exit 64
        fi

        tool="$4"
        shift 4

        if [ "$tool" = "spades.py" ] && { [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; }; then
            printf '%s\n' 'SPAdes 4.2.0'
            exit 0
        fi

        if [ "$tool" != "spades.py" ]; then
            printf '%s\n' "unexpected tool: $tool" >&2
            exit 65
        fi

        : > '\(argsLogPath)'
        for arg in "$@"; do
            printf '%s\n' "$arg" >> '\(argsLogPath)'
        done

        outdir=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "-o" ]; then
                outdir="$arg"
            fi
            prev="$arg"
        done

        if [ -z "$outdir" ]; then
            printf '%s\n' 'missing -o argument' >&2
            exit 66
        fi

        mkdir -p "$outdir"
        \(failureBody)
        """
    }

    private func megahitMicromambaScript(argsLog: URL? = nil) -> String {
        let argsLogPath = argsLog?.path ?? "/dev/null"
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf '%s\\n' '2.0.0'
            exit 0
        fi

        if [ "$1" != "run" ] || [ "$2" != "-n" ]; then
            printf '%s\\n' "unexpected micromamba invocation: $*" >&2
            exit 64
        fi

        tool="$4"
        shift 4

        if [ "$tool" = "megahit" ] && { [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; }; then
            printf '%s\\n' 'MEGAHIT v1.2.9'
            exit 0
        fi

        if [ "$tool" != "megahit" ]; then
            printf '%s\\n' "unexpected tool: $tool" >&2
            exit 65
        fi

        : > '\(argsLogPath)'
        for arg in "$@"; do
            printf '%s\\n' "$arg" >> '\(argsLogPath)'
        done

        outdir=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "-o" ]; then
                outdir="$arg"
            fi
            prev="$arg"
        done

        if [ -z "$outdir" ]; then
            printf '%s\\n' 'missing -o argument' >&2
            exit 66
        fi

        if [ -e "$outdir" ]; then
            printf '%s\\n' "megahit: Output directory $outdir already exists, please change the parameter -o to another value to avoid overwriting." >&2
            exit 1
        fi

        mkdir -p "$outdir"
        printf '>contig1\\nACGT\\n' > "$outdir/final.contigs.fa"
        exit 0
        """
    }
}
