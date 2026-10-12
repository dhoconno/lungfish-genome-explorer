// NextflowStandInEngine.swift - The stand-in micromamba and Nextflow that Nextflow workflow tests run on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9 M1, decision N11 (docs/plans/2026-10-12-phase-2-9.md), grown from the engine of
// 2.8 lane TF-G (decisions T14 and T16 of docs/plans/2026-10-11-phase-2-8.md). It takes the place
// of the managed Nextflow behind `micromamba run -n nextflow nextflow ...`, or behind
// `engineLaunch` for a runner that starts the engine directly, so every step of the caller runs
// around it.
//
// - Each launch is recorded in its own numbered folder under `launchesDirectory`: the argv, the
//   environment, the working directory, the samplesheet bytes and the FASTQ records of every input
//   the samplesheet names, counted while the launch runs (T16). The number is taken with mkdir,
//   which only one launch can win, so launches at once never share a folder. `launches()` reads
//   the records back with the values of `-c`, `-r`, `-profile`, `-w`, `-work-dir` and
//   `-params-file`.
// - A `NextflowStandInWorkflow` writes the per-sample outputs and names the tasks. The engine
//   writes the trace file `-with-trace` names, and what it prints becomes the run's log.
//   `OutputMode.plainLog26` prints the line shapes of Nextflow 26.04.6 with `NXF_ANSI_LOG=false`
//   from Q15's real run R1, and `.progressLines25` prints the lines of 2.8.
// - The engine reports version 25.04.6 build 5954 in `-version` and in every banner, where the
//   lock pins 26.04.6, so a test tells a version its caller read from the engine from the lock's.
// - `Behaviour` fails samples, reports errored tasks, waits until cancelled, or traps TERM with a
//   heartbeat child, the switch lane S1 of 2.8 uses to show the whole tree stops.
//
// Run it with a Nextflow profile other than docker, which skips a caller's Docker check, and other
// than conda, which keeps the conda variables out of the launch environment. The tool root and
// the Nextflow home live in the engine's own `home`, never under the real home. The conda root
// comes from the package initializer of `CondaManager`, so no file under Tests/Support imports a
// module for testing (ARCH API ruling, risk 2).

import Foundation
import LungfishCore
import LungfishWorkflow

/// A stand-in managed Nextflow and micromamba that record each launch and write one workflow's
/// outputs (N11).
public struct NextflowStandInEngine: Sendable {
    /// What the stand-in Nextflow does once it has recorded a launch.
    public enum Behaviour: Sendable, Equatable {
        /// Writes the outputs of every sample and exits 0.
        case completes
        /// Exits 1 with Nextflow's task error, writing no outputs, when the samplesheet names one
        /// of these samples, and completes otherwise. A serial batch launches one sample at a
        /// time, so this fails one sample of the batch.
        case failsSamples(Set<String>)
        /// Writes the outputs, reports one alignment task per sample that failed with exit 137
        /// and was ignored, in trace.txt and in the log, and exits 0, as TaxTriage's ignore
        /// strategy does.
        case reportsErroredTasks
        /// Waits once the launch is marked started. A signal ends it, `release()` lets it complete,
        /// `stopLeftoverProcesses()` ends it with 143, and it gives up with 124 after the
        /// engine's `maximumWait`.
        case waitsUntilCancelled
        /// As `waitsUntilCancelled`, but the engine first starts a child that appends a line to
        /// `Launch.heartbeat` every 0.2 seconds, and both trap TERM, record it and go on. Only
        /// SIGKILL, `release()` or `stopLeftoverProcesses()` ends them. Both traps are set before
        /// the launch is marked started, so a test may signal as soon as `waitForLaunch` returns.
        case trapsTermWithHeartbeatChild
    }

    /// The lines the stand-in Nextflow prints, which become the run's log.
    public enum OutputMode: Sendable, Equatable {
        /// The plain log of Nextflow 26.04.6 with `NXF_ANSI_LOG=false`, in the line shapes of R1:
        /// the workflow's own banner, `[PIPELINE] <name> <version> | profile=<profile>`,
        /// `[WORKDIR] <folder>`, one `[PROCESS <hash>] <task>` line per task as it is submitted,
        /// nf-core's completion line and `[SUCCESS] completed=<n> failed=<n> cached=0`. It prints
        /// no `Submitted process >` and no `[100%]` line. The default for a new workflow.
        case plainLog26
        /// The lines of the 2.8 stand-in, a Nextflow 25.04.6 banner, then `Submitted process >`
        /// and `[100%]` for each sample, which a real 26.04.6 never prints. The TaxTriage wrapper
        /// printed them until lane U10 M1 flipped it to `plainLog26`.
        case progressLines25
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
        /// Every file `-c` named, in argument order.
        public let configFiles: [String]
        /// The revision `-r` named.
        public let revision: String?
        /// The profile `-profile` named.
        public let profile: String?
        /// The work folder `-w` or `-work-dir` named, the last one when the launch names several.
        public let workDirectory: String?
        /// The parameter file `-params-file` named.
        public let paramsFile: String?

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

    /// The version the stand-in reports, in `-version` as build 5954 and in every banner. The
    /// lock pins 26.04.6, so a record that names 26.04.6 took it from the lock, not the engine.
    public static let version = "25.04.6"

    public let root: URL
    /// The home the caller runs with. It holds the tool root and the Nextflow home.
    public let home: URL
    /// The conda root under `home`, with the stand-in micromamba in `bin/` and the stand-in
    /// Nextflow in `envs/nextflow/bin/`, where a caller finds the managed engine.
    public let condaRoot: URL
    public let launchesDirectory: URL
    public let workflow: NextflowStandInWorkflow
    public let behaviour: Behaviour
    public let outputMode: OutputMode
    public let condaManager: CondaManager

    public var micromamba: URL { condaRoot.appendingPathComponent("bin/micromamba") }
    public var nextflow: URL { condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow") }
    /// The folder the workflow's fixtures are copied into. Each launch reads them there, so a test
    /// may change one before it launches.
    public var fixturesDirectory: URL { root.appendingPathComponent("fixtures", isDirectory: true) }

    /// Writes the engine into `root`, which must be empty or absent.
    public init(
        root: URL,
        workflow: NextflowStandInWorkflow,
        behaviour: Behaviour = .completes,
        outputMode: OutputMode = .plainLog26,
        maximumWait: Duration = .seconds(120)
    ) throws {
        self.root = root.standardizedFileURL
        self.workflow = workflow
        self.behaviour = behaviour
        self.outputMode = outputMode
        home = self.root.appendingPathComponent("home", isDirectory: true)
        condaRoot = home.appendingPathComponent(".lungfish/conda", isDirectory: true)
        launchesDirectory = self.root.appendingPathComponent("launches", isDirectory: true)

        let fileManager = FileManager.default
        let fixtures = self.root.appendingPathComponent("fixtures", isDirectory: true)
        let tasks = self.root.appendingPathComponent("workflow", isDirectory: true)
        try fileManager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tasks, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchesDirectory, withIntermediateDirectories: true)
        for fixture in workflow.fixtures {
            try fileManager.copyItem(at: fixture.source, to: fixtures.appendingPathComponent(fixture.name))
        }
        let taskLists = [
            ("leading-processes", workflow.leadingProcessNames),
            ("sample-processes", workflow.processNames),
            ("trailing-processes", workflow.trailingProcessNames),
        ]
        for (name, processes) in taskLists {
            try processes.map { $0 + "\n" }.joined()
                .write(to: tasks.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let micromamba = condaRoot.appendingPathComponent("bin/micromamba")
        try Self.writeExecutable(
            Self.micromambaScript.replacingOccurrences(of: "@CONDA_ROOT@", with: Self.shellQuoted(condaRoot.path)),
            to: micromamba
        )
        let ticks = max(1, Int(maximumWait.components.seconds) * 5)
        let values = [
            ("@FIXTURES@", Self.shellQuoted(fixtures.path)),
            ("@WORKFLOW@", Self.shellQuoted(tasks.path)),
            ("@LAUNCHES@", Self.shellQuoted(launchesDirectory.path)),
            ("@CONTROL@", Self.shellQuoted(self.root.path)),
            ("@BEHAVIOUR@", behaviour.scriptName),
            ("@FAILING@", Self.shellQuoted(behaviour.failingSamples.joined(separator: "\n"))),
            ("@TICKS@", String(ticks)),
            ("@MODE@", outputMode.scriptName),
            ("@WORKFLOW_NAME@", Self.shellQuoted(workflow.name)),
            ("@WORKFLOW_VERSION@", Self.shellQuoted(workflow.version)),
            ("@FAILING_PROCESS@", Self.shellQuoted(workflow.failingProcessName)),
            ("@IGNORED_PROCESS@", Self.shellQuoted(workflow.ignoredFailureProcessName)),
            ("@LEGACY_PROCESS@", Self.shellQuoted(workflow.progressLinesProcessName)),
            ("@LEGACY_IGNORED_PROCESS@", Self.shellQuoted(workflow.progressLinesIgnoredProcessName)),
            ("@LEGACY_REPOSITORY@", Self.shellQuoted(workflow.progressLinesRepository)),
        ]
        var script = Self.nextflowScript
        for (placeholder, value) in values {
            script = script.replacingOccurrences(of: placeholder, with: value)
        }
        // The workflow's functions go in last, so no replacement above reaches into their code.
        script = script.replacingOccurrences(of: "@WORKFLOW_FUNCTIONS@", with: workflow.shellFunctions)
        try Self.writeExecutable(script, to: condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow"))

        condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    /// The launch a runner that starts Nextflow directly takes, as the nf-core and PBAA runners
    /// do. `WorkflowEngineLaunch.resolve` finds this engine as the managed Nextflow of `home`, so
    /// the launch execs the stand-in Nextflow with the environment a real launch gets.
    package var engineLaunch: WorkflowEngineLaunch {
        WorkflowEngineLaunch.resolve(executableName: "nextflow", homeDirectory: home, appIdentity: .preview)
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
        let arguments = nulSeparated("argv")
        let options = EngineOptions(arguments)
        return Launch(
            folder: folder,
            arguments: arguments,
            environment: environment,
            workingDirectory: text("pwd").trimmingCharacters(in: .newlines),
            samplesheet: data("samplesheet.csv"),
            fastqRecords: fastqRecords,
            processIdentifier: number("pid"),
            childProcessIdentifier: number("child.pid"),
            exitStatus: number("exit"),
            trappedSignals: lines("signals"),
            childTrappedSignals: lines("child-signals"),
            configFiles: options.configFiles,
            revision: options.revision,
            profile: options.profile,
            workDirectory: options.workDirectory,
            paramsFile: options.paramsFile
        )
    }

    // MARK: - Files

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
    # Stand-in micromamba of NextflowStandInEngine. `run -n <env> <tool> ...` execs the tool from
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
    # Stand-in Nextflow of NextflowStandInEngine (Tests/Support/LungfishTestSupport), which says
    # what it records and writes.
    fixtures=@FIXTURES@
    workflow=@WORKFLOW@
    launches=@LAUNCHES@
    control=@CONTROL@
    behaviour=@BEHAVIOUR@
    failing=@FAILING@
    ticks=@TICKS@
    mode=@MODE@
    workflow_name=@WORKFLOW_NAME@
    workflow_version=@WORKFLOW_VERSION@
    failing_process=@FAILING_PROCESS@
    ignored_process=@IGNORED_PROCESS@
    legacy_process=@LEGACY_PROCESS@
    legacy_ignored_process=@LEGACY_IGNORED_PROCESS@
    legacy_repository=@LEGACY_REPOSITORY@
    engine_version=25.04.6
    esc=$(printf '\033')

    @WORKFLOW_FUNCTIONS@

    case "$1" in
      -version|--version|-v)
        echo "nextflow version 25.04.6.5954"
        exit 0
        ;;
    esac

    # mkdir takes the record number, and only one launch can win a number, so launches at once
    # never share a record. A launch that loses takes the next number.
    [ -d "$launches" ] || exit 70
    count=$(ls -1 "$launches" | wc -l)
    number=$((count + 1))
    until mkdir "$launches/$(printf '%03d' "$number")" 2>/dev/null; do
      number=$((number + 1))
      [ "$number" -lt 10000 ] || exit 70
    done
    record="$launches/$(printf '%03d' "$number")"
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

    # The options the engine acts on. Launch reads -c, -r, -profile, -w, -work-dir and -params-file
    # from the recorded argv.
    input=""
    outdir=""
    trace=""
    workdir=""
    profile=""
    revision=""
    target=""
    previous=""
    for argument in "$@"; do
      case "$previous" in
        --input) input="$argument" ;;
        --outdir) outdir="$argument" ;;
        -with-trace) trace="$argument" ;;
        -w|-work-dir) workdir="$argument" ;;
        -profile) profile="$argument" ;;
        -r) revision="$argument" ;;
        run) [ -n "$target" ] || target="$argument" ;;
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
        : > "$record/child-trapping"
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
      # The launch is marked started only once the child traps TERM too, so a test may signal at once.
      waited=0
      while [ ! -e "$record/child-trapping" ] && [ "$waited" -lt "$ticks" ]; do
        sleep 0.05
        waited=$((waited + 1))
      done
    fi
    : > "$record/started"
    if [ "$mode" = plain-log-26 ]; then
      workflow_banner
      printf '[PIPELINE] %s %s | profile=%s\n' "$workflow_name" "$workflow_version" "${profile:-standard}"
      printf '[WORKDIR] %s\n' "${workdir:-$(pwd)/work}"
    else
      echo "N E X T F L O W  ~  version 25.04.6"
      echo "Launching $legacy_repository [stand-in] DSL2"
    fi

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
    # Prints $1 with every @SAMPLE@ in it replaced by $2.
    expand() {
      rest=$1
      expanded=""
      while :; do
        case "$rest" in
          *@SAMPLE@*)
            expanded="$expanded${rest%%@SAMPLE@*}$2"
            rest=${rest#*@SAMPLE@}
            ;;
          *)
            printf '%s' "$expanded$rest"
            return 0
            ;;
        esac
      done
    }

    failed=0
    while IFS= read -r sample <&3; do
      if is_failing "$sample"; then
        failed=1
      fi
    done 3< "$samples"

    if [ "$mode" = plain-log-26 ]; then
      completed=0
      errored=0
      # One task, its [PROCESS] line as Nextflow submits it and its trace row: $1 name, $2 status, $3 exit.
      plain_task() {
        printf '[PROCESS aa/%06d] %s\n' "$((task + 1))" "$1"
        trace_row "$1" "$2" "$3"
        if [ "$2" = COMPLETED ]; then
          completed=$((completed + 1))
        else
          errored=$((errored + 1))
        fi
      }
      listed_tasks() {
        while IFS= read -r name <&4; do
          plain_task "$name" COMPLETED 0
        done 4< "$1"
      }
      listed_tasks "$workflow/leading-processes"
      [ "$failed" = 1 ] || workflow_prepare_outputs
      while IFS= read -r sample <&3; do
        while IFS= read -r template <&4; do
          name=$(expand "$template" "$sample")
          if [ "$template" = "$failing_process" ] && is_failing "$sample"; then
            plain_task "$name" FAILED 1
            echo "ERROR ~ Error executing process > '$name'" >&2
          elif [ "$template" = "$ignored_process" ] && [ "$behaviour" = errored-tasks ]; then
            plain_task "$name" FAILED 137
            printf '[aa/%06d] NOTE: Process `%s` terminated with an error exit status (137) -- Error is ignored\n' "$task" "$name"
          else
            plain_task "$name" COMPLETED 0
          fi
          if [ "$failed" = 1 ] && [ "$template" = "$failing_process" ]; then
            break
          fi
        done 4< "$workflow/sample-processes"
        [ "$failed" = 1 ] || workflow_sample_outputs "$sample"
      done 3< "$samples"
      if [ "$failed" = 1 ]; then
        printf '%s\n' "-${esc}[0;35m[$workflow_name]${esc}[0;31m Pipeline completed with errors${esc}[0m-"
        finish 1
      fi
      listed_tasks "$workflow/trailing-processes"
      if [ "$behaviour" = errored-tasks ]; then
        printf '%s\n' "-${esc}[0;35m[$workflow_name]${esc}[0;33m Pipeline completed successfully, but with errored process(es) ${esc}[0m-"
      else
        printf '%s\n' "-${esc}[0;35m[$workflow_name]${esc}[0;32m Pipeline completed successfully${esc}[0m-"
      fi
      printf '[SUCCESS] completed=%s failed=%s cached=0\n' "$completed" "$errored"
      finish 0
    fi

    if [ "$failed" = 1 ]; then
      while IFS= read -r sample <&3; do
        name="$legacy_process ($sample)"
        echo "[aa/000001] Submitted process > $name"
        if is_failing "$sample"; then
          trace_row "$name" FAILED 1
          echo "ERROR ~ Error executing process > '$name'" >&2
        else
          trace_row "$name" COMPLETED 0
        fi
      done 3< "$samples"
      echo "-[$workflow_name] Pipeline completed with errors-"
      finish 1
    fi

    workflow_prepare_outputs
    while IFS= read -r sample <&3; do
      name="$legacy_process ($sample)"
      echo "[aa/000001] Submitted process > $name"
      workflow_sample_outputs "$sample"
      trace_row "$name" COMPLETED 0
      echo "[aa/000001] process > $name [100%] 1 of 1"
      if [ "$behaviour" = errored-tasks ]; then
        trace_row "$legacy_ignored_process ($sample)" FAILED 137
        printf '[bb/000002] NOTE: Process `%s (%s)` terminated with an error exit status (137) -- Error is ignored\n' "$legacy_ignored_process" "$sample"
      fi
    done 3< "$samples"
    if [ "$behaviour" = errored-tasks ]; then
      echo "-[$workflow_name] Pipeline completed successfully, but with errored process(es) -"
    else
      echo "-[$workflow_name] Pipeline completed successfully-"
    fi
    finish 0
    """#
}

/// The engine options of one argv. Each option takes the argument after it.
private struct EngineOptions {
    var configFiles: [String] = []
    var revision: String?
    var profile: String?
    var workDirectory: String?
    var paramsFile: String?

    init(_ arguments: [String]) {
        var index = 0
        while index + 1 < arguments.count {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "-c": configFiles.append(value)
            case "-r": revision = value
            case "-profile": profile = value
            case "-w", "-work-dir": workDirectory = value
            case "-params-file": paramsFile = value
            default:
                index += 1
                continue
            }
            index += 2
        }
    }
}

extension NextflowStandInEngine.Behaviour {
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

extension NextflowStandInEngine.OutputMode {
    /// The name the stand-in Nextflow script switches on.
    var scriptName: String {
        switch self {
        case .plainLog26: return "plain-log-26"
        case .progressLines25: return "progress-lines-25"
        }
    }
}
