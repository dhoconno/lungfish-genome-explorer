// TaxTriageStandInEngine.swift - The stand-in micromamba and Nextflow that TaxTriage tests run on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-G, decisions T14 and T16 (docs/plans/2026-10-11-phase-2-8.md). No test runs
// the real TaxTriage, which needs Docker, container images and NCBI downloads. This engine takes
// the place of the managed Nextflow behind the pipeline's own launch, `micromamba run -n nextflow
// nextflow ...`, so every step of today's `TaxTriagePipeline` runs around it.
//
// - Each launch is recorded in its own folder under `launchesDirectory`: the argv, the environment,
//   the working directory, the samplesheet bytes and the FASTQ records of every input the
//   samplesheet names, counted while the launch runs (T16). `launches()` reads them back.
// - It writes the per-sample tree today's parsers read. `report/<sample>.odr.txt` is the TaxTriage
//   3.3.8 organism discovery report of Tests/Fixtures/taxtriage-odr-3.3.8 with its Specimen ID set
//   to the sample, `combine/<sample>.combined.gcfmap.tsv` its accession map, and
//   `top/<sample>.top_report.tsv` the Kraken top report of Tests/Fixtures/taxtriage-mini. It also
//   writes the trace file that `-with-trace` names, and what it prints becomes the run's
//   nextflow.log. It writes no BAM, so `build-db taxtriage` skips its samtools pass.
// - `Behaviour` fails samples, reports errored tasks, waits until cancelled, or traps TERM with a
//   heartbeat child, the switch lane S1 uses to show the whole tree stops.
//
// Run it with the Nextflow profile `profile`. Any profile but docker skips the pipeline's Docker
// check, and a profile other than conda keeps the conda variables out of the launch environment,
// as a docker run does. The tool root and the Nextflow home live in the engine's own `home`, never
// under the real home.
//
// The engine builds its conda root with the test initializer of `CondaManager`, which is internal
// to LungfishWorkflow, so this file imports it `@testable` behind `#if DEBUG`, for the reason
// FakeClassificationCondaFixture.swift gives.

import Foundation
#if DEBUG
@testable import LungfishWorkflow

public struct TaxTriageStandInEngine: Sendable {
    /// What the stand-in Nextflow does once it has recorded a launch.
    public enum Behaviour: Sendable, Equatable {
        /// Writes the outputs of every sample and exits 0.
        case completes
        /// Exits 1 with Nextflow's task error, writing no outputs, when the samplesheet names one
        /// of these samples, and completes otherwise. A serial batch launches one sample at a
        /// time, so this fails one sample of the batch.
        case failsSamples(Set<String>)
        /// Writes the outputs, reports one MINIMAP2_ALIGN task per sample that failed with exit
        /// 137 and was ignored, in trace.txt and in the log, and exits 0, as TaxTriage's ignore
        /// strategy does.
        case reportsErroredTasks
        /// Waits once the launch is marked started. A signal ends it, `release()` lets it complete,
        /// `stopLeftoverProcesses()` ends it with 143, and it gives up with 124 after the
        /// engine's `maximumWait`.
        case waitsUntilCancelled
        /// As `waitsUntilCancelled`, but the engine first starts a child that appends a line to
        /// `Launch.heartbeat` every 0.2 seconds, and both trap TERM, record it and go on. Only
        /// SIGKILL, `release()` or `stopLeftoverProcesses()` ends them.
        case trapsTermWithHeartbeatChild
    }

    /// One launch of the stand-in Nextflow, read back from its record folder.
    public struct Launch: Sendable {
        public let folder: URL
        /// The Nextflow arguments, without the `micromamba run -n nextflow nextflow` prefix.
        public let arguments: [String]
        public let environment: [String: String]
        public let workingDirectory: String
        /// The bytes of the samplesheet `--input` named, copied when the launch started.
        public let samplesheet: Data
        public let fastqRecords: [FASTQRecords]
        public let processIdentifier: Int32?
        /// The heartbeat child of `trapsTermWithHeartbeatChild`.
        public let childProcessIdentifier: Int32?
        /// The status the engine exited with on its own, nil while it runs or after a signal.
        public let exitStatus: Int32?
        /// One `TERM` line per TERM the engine trapped, and the same for its child.
        public let trappedSignals: [String]
        public let childTrappedSignals: [String]

        /// The file the heartbeat child appends to.
        public var heartbeat: URL { folder.appendingPathComponent("heartbeat") }

        /// The argument that follows `option`, such as the folder after `--outdir`.
        public func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    /// The FASTQ records one samplesheet column named, counted as lines over four. A file the
    /// engine could not read counts -1.
    public struct FASTQRecords: Sendable, Equatable, CustomStringConvertible {
        public let sample: String
        /// `fastq_1` or `fastq_2`.
        public let column: String
        public let path: String
        public let records: Int

        public init(sample: String, column: String, path: String, records: Int) {
            self.sample = sample
            self.column = column
            self.path = path
            self.records = records
        }

        public var description: String { "\(sample) \(column) \(records) \(path)" }
    }

    /// The Nextflow profile a stand-in run uses.
    public static let profile = "local"

    public let root: URL
    /// The home the pipeline runs with. It holds the tool root and the Nextflow home.
    public let home: URL
    /// The conda root under `home`, with the stand-in micromamba in `bin/` and the stand-in
    /// Nextflow in `envs/nextflow/bin/`, where the pipeline finds the managed engine.
    public let condaRoot: URL
    public let launchesDirectory: URL
    public let behaviour: Behaviour
    public let condaManager: CondaManager

    public var micromamba: URL { condaRoot.appendingPathComponent("bin/micromamba") }
    public var nextflow: URL { condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow") }

    /// Writes the engine into `root`, which must be empty or absent.
    public init(root: URL, behaviour: Behaviour = .completes, maximumWait: Duration = .seconds(120)) throws {
        self.root = root.standardizedFileURL
        self.behaviour = behaviour
        home = self.root.appendingPathComponent("home", isDirectory: true)
        condaRoot = home.appendingPathComponent(".lungfish/conda", isDirectory: true)
        launchesDirectory = self.root.appendingPathComponent("launches", isDirectory: true)

        let fileManager = FileManager.default
        let fixtures = self.root.appendingPathComponent("fixtures", isDirectory: true)
        try fileManager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchesDirectory, withIntermediateDirectories: true)
        for (name, source) in Self.fixtureSources {
            try fileManager.copyItem(at: source, to: fixtures.appendingPathComponent(name))
        }

        let micromamba = condaRoot.appendingPathComponent("bin/micromamba")
        try Self.writeExecutable(
            Self.micromambaScript.replacingOccurrences(of: "@CONDA_ROOT@", with: Self.shellQuoted(condaRoot.path)),
            to: micromamba
        )
        let ticks = max(1, Int(maximumWait.components.seconds) * 5)
        let script = Self.nextflowScript
            .replacingOccurrences(of: "@FIXTURES@", with: Self.shellQuoted(fixtures.path))
            .replacingOccurrences(of: "@LAUNCHES@", with: Self.shellQuoted(launchesDirectory.path))
            .replacingOccurrences(of: "@CONTROL@", with: Self.shellQuoted(self.root.path))
            .replacingOccurrences(of: "@BEHAVIOUR@", with: behaviour.scriptName)
            .replacingOccurrences(of: "@FAILING@", with: Self.shellQuoted(behaviour.failingSamples.joined(separator: "\n")))
            .replacingOccurrences(of: "@TICKS@", with: String(ticks))
        try Self.writeExecutable(script, to: condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow"))

        condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    // MARK: - Running

    /// A pipeline that launches this engine, as the CLI's pipeline factory needs.
    public func makePipeline(processManager: ProcessManager = .shared) -> TaxTriagePipeline {
        let home = home
        return TaxTriagePipeline(
            processManager: processManager,
            condaManager: condaManager,
            homeDirectoryProvider: { home },
            appIdentity: .preview
        )
    }

    /// The pipeline run of `TaxTriageSerialBatchRunner(runPipeline:)` that launches this engine.
    public var pipelineRun: TaxTriageSerialBatchRunner.PipelineRun {
        let engine = self
        return { config, progress in
            try await engine.makePipeline().run(config: config, progress: progress)
        }
    }

    /// A serial batch runner on this engine, as the GUI's runner factory needs.
    public func makeRunner() -> TaxTriageSerialBatchRunner {
        TaxTriageSerialBatchRunner(runPipeline: pipelineRun)
    }

    // MARK: - Control

    /// Lets every waiting launch, and every later one, go on as `completes` would.
    public func release() {
        FileManager.default.createFile(atPath: root.appendingPathComponent("release").path, contents: nil)
    }

    /// Ends every waiting launch and heartbeat child with 143, then waits until no recorded
    /// process is alive or `timeout` passes. Call it in teardown, so no stand-in outlives its test.
    public func stopLeftoverProcesses(timeout: Duration = .seconds(30)) async {
        FileManager.default.createFile(atPath: root.appendingPathComponent("stop").path, contents: nil)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let identifiers = ((try? launches()) ?? []).flatMap {
                [$0.processIdentifier, $0.childProcessIdentifier].compactMap { $0 }
            }
            if !identifiers.contains(where: { kill($0, 0) == 0 }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Records

    /// Every launch that has started or exited, in launch order.
    public func launches() throws -> [Launch] {
        let fileManager = FileManager.default
        let folders = try fileManager.contentsOfDirectory(
            at: launchesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try folders.compactMap { folder in
            guard fileManager.fileExists(atPath: folder.appendingPathComponent("started").path)
                || fileManager.fileExists(atPath: folder.appendingPathComponent("exit").path) else {
                return nil
            }
            return try Self.readLaunch(in: folder)
        }
    }

    /// The launch at `index` once it has started, or nil when `timeout` passes first.
    public func waitForLaunch(_ index: Int = 0, timeout: Duration = .seconds(30)) async -> Launch? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let launches = try? launches(), launches.indices.contains(index) {
                return launches[index]
            }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func readLaunch(in folder: URL) throws -> Launch {
        func data(_ name: String) -> Data {
            (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data()
        }
        func text(_ name: String) -> String {
            String(decoding: data(name), as: UTF8.self)
        }
        func lines(_ name: String) -> [String] {
            text(name).split(separator: "\n").map(String.init)
        }
        func number(_ name: String) -> Int32? {
            Int32(text(name).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func nulSeparated(_ name: String) -> [String] {
            data(name).split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
                String(decoding: $0, as: UTF8.self)
            }
        }

        var environment: [String: String] = [:]
        for entry in nulSeparated("environment") {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        let fastqRecords = lines("fastq-records.tsv").compactMap { line -> FASTQRecords? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 4, let records = Int(fields[3]) else { return nil }
            return FASTQRecords(sample: fields[0], column: fields[1], path: fields[2], records: records)
        }
        return Launch(
            folder: folder,
            arguments: nulSeparated("argv"),
            environment: environment,
            workingDirectory: text("pwd").trimmingCharacters(in: .newlines),
            samplesheet: data("samplesheet.csv"),
            fastqRecords: fastqRecords,
            processIdentifier: number("pid"),
            childProcessIdentifier: number("child.pid"),
            exitStatus: number("exit"),
            trappedSignals: lines("signals"),
            childTrappedSignals: lines("child-signals")
        )
    }

    // MARK: - Files

    /// The fixture files the stand-in copies into each result, by the name it reads them under.
    private static var fixtureSources: [(String, URL)] {
        let fixtures = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
        return [
            ("odr.txt", fixtures.appendingPathComponent("taxtriage-odr-3.3.8/SRR12486983/report/SRR12486983.odr.txt")),
            ("gcfmap.tsv", fixtures.appendingPathComponent("taxtriage-odr-3.3.8/SRR12486983/combine/SRR12486983.combined.gcfmap.tsv")),
            ("top_report.tsv", fixtures.appendingPathComponent("taxtriage-mini/top/SRR35517702.top_report.tsv")),
        ]
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `value` in single quotes for `/bin/sh`.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let micromambaScript = #"""
    #!/bin/sh
    # Stand-in micromamba of TaxTriageStandInEngine. `run -n <env> <tool> ...` execs the tool from
    # this conda root, as micromamba does.
    root=@CONDA_ROOT@
    if [ "$1" = "--version" ]; then
      echo "2.0.0"
      exit 0
    fi
    if [ "$1" != "run" ] || [ "$2" != "-n" ] || [ -z "$3" ] || [ -z "$4" ]; then
      echo "stand-in micromamba: unexpected invocation: $*" >&2
      exit 64
    fi
    environment="$3"
    tool="$4"
    shift 4
    exec "$root/envs/$environment/bin/$tool" "$@"
    """#

    private static let nextflowScript = #"""
    #!/bin/sh
    # Stand-in Nextflow of TaxTriageStandInEngine (Tests/Support/LungfishTestSupport), which says
    # what it records and writes.
    fixtures=@FIXTURES@
    launches=@LAUNCHES@
    control=@CONTROL@
    behaviour=@BEHAVIOUR@
    failing=@FAILING@
    ticks=@TICKS@

    case "$1" in
      -version|--version|-v)
        echo "nextflow version 25.04.6.5954"
        exit 0
        ;;
    esac

    count=$(ls -1 "$launches" | wc -l)
    record="$launches/$(printf '%03d' $((count + 1)))"
    mkdir "$record" || exit 70
    printf '%s\n' "$$" > "$record/pid"
    pwd > "$record/pwd"
    env -0 > "$record/environment"
    for argument in "$@"; do
      printf '%s\0' "$argument"
    done > "$record/argv"

    finish() {
      printf '%s\n' "$1" > "$record/exit"
      exit "$1"
    }

    input=""
    outdir=""
    trace=""
    workdir=""
    previous=""
    for argument in "$@"; do
      case "$previous" in
        --input) input="$argument" ;;
        --outdir) outdir="$argument" ;;
        -with-trace) trace="$argument" ;;
        -w) workdir="$argument" ;;
      esac
      previous="$argument"
    done
    if [ -z "$input" ] || [ -z "$outdir" ] || [ ! -r "$input" ]; then
      echo "ERROR ~ The stand-in Nextflow needs a readable --input and an --outdir" >&2
      finish 64
    fi
    cp "$input" "$record/samplesheet.csv"

    # Fields split at commas, so a quoted samplesheet field is not read. Sample names go one per
    # line into `samples`, so a name may hold spaces.
    samples="$record/samples"
    header=1
    : > "$samples"
    : > "$record/fastq-records.tsv"
    while IFS=, read -r sample fastq1 fastq2 platform <&3 || [ -n "$sample" ]; do
      if [ "$header" = 1 ]; then
        header=0
        continue
      fi
      [ -n "$sample" ] || continue
      printf '%s\n' "$sample" >> "$samples"
      column=fastq_1
      for path in "$fastq1" "$fastq2"; do
        if [ -n "$path" ]; then
          reads=-1
          if [ -r "$path" ]; then
            case "$path" in
              *.gz) lines=$(gzip -cd < "$path" | wc -l) ;;
              *) lines=$(wc -l < "$path") ;;
            esac
            reads=$((lines / 4))
          fi
          printf '%s\t%s\t%s\t%s\n' "$sample" "$column" "$path" "$reads" >> "$record/fastq-records.tsv"
        fi
        column=fastq_2
      done
    done 3< "$input"

    if [ -n "$workdir" ]; then
      mkdir -p "$workdir/aa/000001" && : > "$workdir/aa/000001/.command.log"
    fi

    if [ "$behaviour" = trap-term ]; then
      (
        trap 'echo TERM >> "$record/child-signals"' TERM
        beat=0
        while [ "$beat" -lt "$ticks" ]; do
          [ -e "$control/stop" ] && exit 143
          [ -e "$control/release" ] && exit 0
          echo "$beat" >> "$record/heartbeat"
          sleep 0.2
          beat=$((beat + 1))
        done
        exit 124
      ) &
      printf '%s\n' "$!" > "$record/child.pid"
      trap 'echo TERM >> "$record/signals"' TERM
    fi
    : > "$record/started"
    echo "N E X T F L O W  ~  version 25.04.6"
    echo "Launching jhuapl-bio/taxtriage [stand-in] DSL2"

    if [ "$behaviour" = wait ] || [ "$behaviour" = trap-term ]; then
      tick=0
      while [ ! -e "$control/release" ]; do
        [ -e "$control/stop" ] && finish 143
        if [ "$tick" -ge "$ticks" ]; then
          echo "ERROR ~ The stand-in Nextflow waited past its limit" >&2
          finish 124
        fi
        sleep 0.2
        tick=$((tick + 1))
      done
    fi

    task=0
    if [ -n "$trace" ]; then
      mkdir -p "$(dirname "$trace")"
      printf 'task_id\thash\tnative_id\tname\tstatus\texit\n' > "$trace"
    fi
    trace_row() {
      task=$((task + 1))
      if [ -n "$trace" ]; then
        printf '%s\taa/%06d\t%s\t%s\t%s\t%s\n' "$task" "$task" "$((1000 + task))" "$1" "$2" "$3" >> "$trace"
      fi
    }
    is_failing() {
      printf '%s\n' "$failing" | grep -Fxq -- "$1"
    }

    failed=0
    while IFS= read -r sample <&3; do
      if is_failing "$sample"; then
        failed=1
      fi
    done 3< "$samples"
    if [ "$failed" = 1 ]; then
      while IFS= read -r sample <&3; do
        name="NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 ($sample)"
        echo "[aa/000001] Submitted process > $name"
        if is_failing "$sample"; then
          trace_row "$name" FAILED 1
          echo "ERROR ~ Error executing process > '$name'" >&2
        else
          trace_row "$name" COMPLETED 0
        fi
      done 3< "$samples"
      echo "-[nf-core/taxtriage] Pipeline completed with errors-"
      finish 1
    fi

    mkdir -p "$outdir/report" "$outdir/combine" "$outdir/top"
    while IFS= read -r sample <&3; do
      name="NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 ($sample)"
      echo "[aa/000001] Submitted process > $name"
      awk -F '\t' -v OFS='\t' -v sample="$sample" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "Specimen ID") column = i; print; next }
        { if (column) $column = sample; print }
      ' "$fixtures/odr.txt" > "$outdir/report/$sample.odr.txt"
      cp "$fixtures/gcfmap.tsv" "$outdir/combine/$sample.combined.gcfmap.tsv"
      cp "$fixtures/top_report.tsv" "$outdir/top/$sample.top_report.tsv"
      trace_row "$name" COMPLETED 0
      echo "[aa/000001] process > $name [100%] 1 of 1"
      if [ "$behaviour" = errored-tasks ]; then
        alignment="NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN"
        trace_row "$alignment ($sample)" FAILED 137
        printf '[bb/000002] NOTE: Process `%s (%s)` terminated with an error exit status (137) -- Error is ignored\n' "$alignment" "$sample"
      fi
    done 3< "$samples"
    if [ "$behaviour" = errored-tasks ]; then
      echo "-[nf-core/taxtriage] Pipeline completed successfully, but with errored process(es) -"
    else
      echo "-[nf-core/taxtriage] Pipeline completed successfully-"
    fi
    finish 0
    """#
}

extension TaxTriageStandInEngine.Behaviour {
    /// The name the stand-in Nextflow script switches on.
    var scriptName: String {
        switch self {
        case .completes: return "completes"
        case .failsSamples: return "fails-samples"
        case .reportsErroredTasks: return "errored-tasks"
        case .waitsUntilCancelled: return "wait"
        case .trapsTermWithHeartbeatChild: return "trap-term"
        }
    }

    var failingSamples: [String] {
        guard case .failsSamples(let samples) = self else { return [] }
        return samples.sorted()
    }
}
#endif
