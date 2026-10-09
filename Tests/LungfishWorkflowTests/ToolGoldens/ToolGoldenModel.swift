// ToolGoldenModel.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The declarative case table for ToolOutputGoldenTests (review finding R7,
// Phase 2.2 lane 1B). Each case names one external tool, the LGE runner that
// serves it today, the argv it runs and what is compared byte for byte.
//
// Argv and output paths use three placeholders, resolved per test run:
//   {in}      the staged copy of the case's fixture inputs
//   {work}    the working directory the runner launches the tool in
//   {storage} the managed storage root (LUNGFISH_STORAGE_ROOT)

import Foundation
@testable import LungfishWorkflow

/// The LGE process runner a case goes through.
enum ToolGoldenRunner: Sendable {
    /// `NativeToolRunner.run(_:arguments:workingDirectory:environment:timeout:)`.
    case nativeTool(NativeTool)
    /// `NativeToolRunner.runProcess(executableURL:...)` on a managed executable
    /// at `<conda root>/envs/<environment>/bin/<executable>`.
    case nativeProcess(environment: String, executable: String)
    /// `NativeToolRunner.runWithFileOutput(_:arguments:outputFile:...)`. The
    /// output path takes the same placeholders as argv.
    case nativeFileOutput(NativeTool, outputFile: String)
    /// `NativeToolRunner.runPipeline(_:...)`, one tool per stage. The case's
    /// `stages` holds the argv of each stage in order.
    case pipeline([NativeTool])
    /// `CondaManager.runTool(name:arguments:environment:workingDirectory:timeout:)`,
    /// which runs `micromamba run -n <environment> <executable>`.
    case conda(environment: String, executable: String)
    /// `ProcessManager.runAndWait(executable:arguments:workingDirectory:environment:)`
    /// on the launch `WorkflowEngineLaunch.resolveManaged` builds for the engine.
    case processManager(engine: String)

    var kind: String {
        switch self {
        case .nativeTool: return "nativeTool"
        case .nativeProcess: return "nativeProcess"
        case .nativeFileOutput: return "nativeFileOutput"
        case .pipeline: return "pipeline"
        case .conda: return "conda"
        case .processManager: return "processManager"
        }
    }

    var detail: String {
        switch self {
        case .nativeTool(let tool): return "NativeToolRunner.run(.\(tool.rawValue))"
        case .nativeProcess(let env, let exe): return "NativeToolRunner.runProcess(envs/\(env)/bin/\(exe))"
        case .nativeFileOutput(let tool, let output): return "NativeToolRunner.runWithFileOutput(.\(tool.rawValue)) > \(output)"
        case .pipeline(let tools): return "NativeToolRunner.runPipeline(" + tools.map { ".\($0.rawValue)" }.joined(separator: " | ") + ")"
        case .conda(let env, let exe): return "CondaManager.runTool(name: \(exe), environment: \(env))"
        case .processManager(let engine): return "ProcessManager.runAndWait(\(engine))"
        }
    }
}

/// Owner ruling on depth. Light tools compare stdout, exit code and named
/// outputs. Heavy tools compare only a version probe and one error path.
enum ToolGoldenTier: String, Sendable {
    case light
    case heavy
}

/// A named output a case compares after the run.
enum ToolGoldenOutput: Sendable {
    /// The file's bytes, normalized when it is text. Stored as a SHA-256 and a
    /// summary when it is larger than the size threshold.
    case file(String, name: String)
    /// A BAM, compared as `samtools view --no-PG` records (SHA-256 and count)
    /// and its `samtools view -H --no-PG` header, both run through
    /// `NativeToolRunner.run`.
    case bam(String, name: String)
    /// The path must not exist after the run, as for a failed run whose
    /// partial output the runner removes.
    case absent(String, name: String)

    var name: String {
        switch self {
        case .file(_, let name), .bam(_, let name), .absent(_, let name): return name
        }
    }
}

/// A run-dependent field a case's output provably holds. Every mask is listed
/// with its reason in Tests/Fixtures/golden/tools/README.md.
enum ToolGoldenMask: String, Sendable, CaseIterable {
    /// Bracken prints the wall-clock start and end of `est_abundance.py`.
    case brackenProgramTime = "bracken-program-time"
    /// LoFreq writes the run date into the VCF header.
    case lofreqFileDate = "lofreq-file-date"
    /// The SRA Toolkit stamps every log line with the UTC wall-clock time.
    case sraLogTimestamp = "sra-log-timestamp"

    var pattern: String {
        switch self {
        case .brackenProgramTime: return #"(PROGRAM (?:START|END) TIME: )\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}"#
        case .lofreqFileDate: return #"(##fileDate=)\d{8}"#
        case .sraLogTimestamp: return #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?= )"#
        }
    }

    var template: String {
        switch self {
        case .brackenProgramTime: return "$1<TIMESTAMP>"
        case .lofreqFileDate: return "$1<DATE>"
        case .sraLogTimestamp: return "<TIMESTAMP>"
        }
    }

    func apply(to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// A run through the same runner before the compared run, such as building the
/// index a later step reads. Its output is not compared but it must exit 0.
struct ToolGoldenSetupStep: Sendable {
    let runner: ToolGoldenRunner
    let argv: [String]
}

/// One row of the case table.
struct ToolGoldenCase: Sendable {
    let id: String
    let tool: String
    let runner: ToolGoldenRunner
    let tier: ToolGoldenTier
    /// Argv per stage. Single-stage runners have exactly one entry.
    let stages: [[String]]
    /// Fixture paths relative to Tests/Fixtures, copied into {in}.
    let inputs: [String]
    /// Generated inputs, written into {in} before the run.
    let generated: [ToolGoldenGeneratedInput]
    let setup: [ToolGoldenSetupStep]
    let outputs: [ToolGoldenOutput]
    /// Compare stderr. Set for error paths and for version probes that print
    /// the version on stderr.
    let compareStderr: Bool
    let masks: [ToolGoldenMask]
    /// Managed databases the case reads, relative to {storage}.
    let databases: [String]
    /// Extra environment variables for the run, after placeholder resolution.
    let environment: [String: String]
    let timeout: TimeInterval

    init(
        _ id: String,
        tool: String,
        runner: ToolGoldenRunner,
        tier: ToolGoldenTier = .light,
        argv: [String] = [],
        stages: [[String]]? = nil,
        inputs: [String] = [],
        generated: [ToolGoldenGeneratedInput] = [],
        setup: [ToolGoldenSetupStep] = [],
        outputs: [ToolGoldenOutput] = [],
        compareStderr: Bool = false,
        masks: [ToolGoldenMask] = [],
        databases: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 300
    ) {
        self.id = id
        self.tool = tool
        self.runner = runner
        self.tier = tier
        self.stages = stages ?? [argv]
        self.inputs = inputs
        self.generated = generated
        self.setup = setup
        self.outputs = outputs
        self.compareStderr = compareStderr
        self.masks = masks
        self.databases = databases
        self.environment = environment
        self.timeout = timeout
    }

    /// The `case.txt` golden, so a change to the table shows as a diff.
    var descriptor: String {
        var lines = [
            "id: \(id)",
            "tool: \(tool)",
            "tier: \(tier.rawValue)",
            "runner: \(runner.kind)",
            "call: \(runner.detail)",
            "compares: " + comparedItems.joined(separator: ", "),
        ]
        if !masks.isEmpty {
            lines.append("masks: " + masks.map(\.rawValue).joined(separator: ", "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var comparedItems: [String] {
        var items = ["argv", "exit", "stdout"]
        if compareStderr { items.append("stderr") }
        items += outputs.map { "outputs/\($0.name)" }
        return items
    }
}

/// A small input the harness writes before the run, deterministic by construction.
struct ToolGoldenGeneratedInput: Sendable {
    let name: String
    let contents: @Sendable (_ inputDirectory: URL) throws -> Data
}

/// Shared argv fragments and fixture paths used by the case tables.
enum ToolGoldenFixtures {
    static let bam = "sarscov2/test.paired_end.sorted.bam"
    static let bai = "sarscov2/test.paired_end.sorted.bam.bai"
    static let genome = "sarscov2/genome.fasta"
    static let genomeFai = "sarscov2/genome.fasta.fai"
    static let r1 = "sarscov2/test_1.fastq.gz"
    static let r2 = "sarscov2/test_2.fastq.gz"
    static let vcf = "sarscov2/test.vcf"
    static let vcfGz = "sarscov2/test.vcf.gz"
    static let vcfTbi = "sarscov2/test.vcf.gz.tbi"
    static let bed = "sarscov2/test.bed"
    static let plainFastq = "read-pairing/kraken2/unmerged_R1.fastq"
    static let msaInput = "phylogenetics/known-sarcopterygian/alignment.fasta"

    static let inBAM = "{in}/test.paired_end.sorted.bam"
    static let inGenome = "{in}/genome.fasta"
    static let inR1 = "{in}/test_1.fastq.gz"
    static let inR2 = "{in}/test_2.fastq.gz"

    static let krakenViralDB = "databases/kraken2/viral"

    /// Two 300-base windows of the SARS-CoV-2 fixture genome, one of them
    /// reverse-complemented, as a BLAST query.
    static let blastQuery = ToolGoldenGeneratedInput(name: "query.fasta") { inputDirectory in
        let fasta = try String(contentsOf: inputDirectory.appendingPathComponent("genome.fasta"), encoding: .utf8)
        let sequence = fasta.split(separator: "\n").dropFirst().joined()
        let bases = Array(sequence)
        let forward = String(bases[1_000..<1_300])
        let reverse = String(bases[20_000..<20_300].reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "T": return "A"
            case "C": return "G"
            case "G": return "C"
            default: return "N"
            }
        })
        return Data(">window_1001_1300\n\(forward)\n>window_20001_20300_rc\n\(reverse)\n".utf8)
    }

    /// A step-function coverage track over the fixture contig.
    static let bedGraph = ToolGoldenGeneratedInput(name: "coverage.bedGraph") { _ in
        var lines: [String] = []
        var start = 0
        var index = 0
        while start < 29_829 {
            let end = min(start + 500, 29_829)
            lines.append("MT192765.1\t\(start)\t\(end)\t\((index * 7) % 23)")
            start = end
            index += 1
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static let chromSizes = ToolGoldenGeneratedInput(name: "chrom.sizes") { _ in
        Data("MT192765.1\t29829\n".utf8)
    }

    /// Prints the argv and environment `micromamba run` hands the tool. Only
    /// key names are printed for variables whose values belong to this Mac
    /// (HOME, TMPDIR, the user text encoding), so the golden holds the
    /// environment's shape and every value the runner decides.
    static let condaEnvironmentProbe =
        "import os, sys; print('argv=' + repr(sys.argv[1:])); "
        + "[print('key=' + k) for k in sorted(os.environ)]; "
        + "[print(k + '=' + os.environ.get(k, '<unset>')) for k in "
        + "('PATH', 'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'CONDA_SHLVL', 'MAMBA_ROOT_PREFIX', 'PWD', 'LC_ALL')]"
}
