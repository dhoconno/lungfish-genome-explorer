// ProvenanceExportPlan.swift - The export-ready shape of a recorded run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A record is a faithful transcript of what LGE ran: internal staging steps
// that symlink an input into a scratch workspace, a mpileup and a call joined
// by a pipe pseudo-file, executables under the managed conda root, and the
// absolute paths of the machine that ran it. None of that is what a
// scientist should read or run. This plan settles all of it once for every
// renderer:
//
// - a `lungfish-internal` step whose outputs are byte-identical copies of
//   its inputs is an alias and disappears; every later reference to a staged
//   copy names the real source;
// - a `stage-reference --mode decompress-gzip` step becomes `gzip -dc`;
// - a step writing `pipe:stdout:X` and the step reading it become one
//   pipeline that keeps the identity of each stage;
// - a step that a `lungfish-cli` step ran inside is a sub-step, named in a
//   comment and not run again (`ProvenanceExportPlan+SubSteps.swift`);
// - `lungfish-internal` and GUI steps are in-app (recorded, not replayed);
// - a managed executable is spelt bare and its environment kept as a pin;
// - a path inside any `.lungfish` project is spelt relative to the project,
//   a scratch output lands under `results/`, and an external input is a
//   parameter with the recorded path as its default.

import Foundation
import LungfishCore

struct ProvenanceExportPlan {
    enum Kind: Equatable {
        /// An external tool the export runs.
        case tool
        /// LGE's own command line, replayable where `lungfish-cli` exists.
        case wrapper
        /// An in-app action: recorded for audit, not replayed.
        case inApp
    }

    /// Where a recorded path lives once it is made portable.
    enum MappedPath: Hashable {
        /// Relative to the `.lungfish` project (`Analyses/.../aln.bam`).
        case project(String)
        /// Produced by the run outside the project (`results/reference.fa`).
        case result(String)
        /// Read from outside the project; spelt as recorded.
        case external(String)
        /// Not a file path (`pipe:stdout:x`, a placeholder).
        case verbatim(String)

        var filename: String {
            switch self {
            case .project(let p), .result(let p), .external(let p), .verbatim(let p):
                // The project root itself (an empty project-relative path)
                // is the process's working directory. `URL(fileURLWithPath:)`
                // resolves an empty path against the current directory, which
                // would spell it as whatever folder the exporter runs in.
                guard !p.isEmpty else { return "." }
                return URL(fileURLWithPath: p).lastPathComponent
            }
        }
    }

    struct Command: Equatable {
        var argv: [String]
        /// A shell redirection of standard output, for a decompression
        /// rewritten from a staging step.
        var stdoutPath: String?
    }

    struct Step {
        /// The recorded 1-based numbers folded into this step.
        let numbers: [Int]
        let toolName: String
        /// The identity of each stage, parallel to `commands`: one for a single tool, and for a pipe one for each tool
        /// in pipe order, so a tool piped after another keeps its own name, version and package.
        let stageIdentities: [ProvenanceToolIdentityText]
        /// The managed environment the step ran in, pinned to a package. It is the entry of
        /// `ProvenanceExportPlan.environments` that holds this step's own spec, so two steps of
        /// one environment that disagree each name their own.
        let environment: ProvenanceManagedEnvironment?
        let kind: Kind
        /// One command, or several joined by pipes.
        let commands: [Command]
        let inputs: [FileRecord]
        let outputs: [FileRecord]
        let wallTime: TimeInterval?
        let containerImage: String?
        let containerDigest: String?
        let isSuccess: Bool
        /// Plumbing (a decompression) that scripts keep and methods omit.
        let isPlumbing: Bool
        let sourceSteps: [StepExecution]
        /// The recorded number of the CLI step this step ran inside, when it is a sub-step the
        /// scripts leave out because that step runs it. See `ProvenanceExportPlan+SubSteps.swift`.
        let ranUnder: Int?

        var number: Int { numbers[0] }
        /// The first stage's identity, which labels the step in a script and pins its environment. The methods text
        /// reads `stageIdentities`, because a tool later in a pipe is not the first stage.
        var identity: ProvenanceToolIdentityText { stageIdentities[0] }
        var isReplayable: Bool { kind != .inApp }

        /// `mpileup`, `call`: the verb after each executable, when it is one.
        var subcommands: [String] {
            commands.compactMap { command in
                guard command.argv.count >= 2, !command.argv[1].hasPrefix("-") else { return nil }
                let verb = command.argv[1]
                guard !verb.contains("/"), !verb.contains("="), !verb.contains(".") else { return nil }
                return verb
            }
        }

        /// The argv the recorder captured (the first command's), for readers
        /// that want the audit form.
        var recordedArgv: [String] { sourceSteps.first?.command ?? [] }
    }

    /// A file some step reads that no earlier replayable step wrote.
    struct Parameter: Equatable {
        let filename: String
        let path: MappedPath
        var name: String { WorkflowExportGraph.sanitize(filename.replacingOccurrences(of: ".", with: "_")) }
    }

    let steps: [Step]
    /// Staging steps folded away, with their recorded numbers.
    let collapsed: [(number: Int, step: StepExecution)]
    /// One entry for each package the run's tool steps installed, in first-use order. Two steps of
    /// one environment that disagree on the package keep both specs, and the later one is a variant
    /// of the environment with its own file name, so no spec is dropped.
    let environments: [ProvenanceManagedEnvironment]
    /// Every recorded `.lungfish` project root seen, as recorded.
    let projectRoots: [String]
    private let mapper: PathMapper

    /// The plan of `run`. `replayArguments` selects each step's replay argv
    /// and returns nil for a step that has none (a GUI action). `lock` is the
    /// managed tool lock that names the package of each environment.
    init(run: WorkflowRun, replayArguments: (StepExecution) -> [String]?, lock: ManagedToolLock = .bundled) {
        let numbered = run.steps.enumerated().map { (number: $0.offset + 1, step: $0.element) }

        // 1. Alias staging copies to their sources.
        var aliases: [String: String] = [:]
        var collapsed: [(number: Int, step: StepExecution)] = []
        for (number, step) in numbered where Self.isInternal(step) {
            let outputs = step.outputs.filter { !$0.path.hasPrefix("pipe:") }
            guard !outputs.isEmpty else { continue }
            var stepAliases: [String: String] = [:]
            for output in outputs {
                guard let sha = output.sha256,
                      let source = step.inputs.first(where: { $0.sha256 == sha && $0.path != output.path }) else {
                    stepAliases = [:]
                    break
                }
                stepAliases[output.path] = source.path
            }
            guard !stepAliases.isEmpty else { continue }
            aliases.merge(stepAliases) { old, _ in old }
            collapsed.append((number, step))
        }
        let collapsedNumbers = Set(collapsed.map(\.number))

        // An input that is a byte copy of an earlier output under another
        // name (a rename LGE made between two tools, a bundle's copy of the
        // reference) is that output; a step's outputs named after such an
        // input (its index) follow it.
        let producedPaths = Set(numbered.filter { !collapsedNumbers.contains($0.number) }
            .flatMap { $0.step.outputs.map(\.path) }.filter { !$0.hasPrefix("pipe:") })
        var producedEarlierByChecksum: [String: String] = [:]
        for (number, step) in numbered where !collapsedNumbers.contains(number) {
            for input in step.inputs where !input.path.hasPrefix("pipe:") && !producedPaths.contains(input.path) {
                guard let sha = input.sha256, let source = producedEarlierByChecksum[sha], source != input.path,
                      aliases[input.path] == nil else { continue }
                aliases[input.path] = source
                for output in step.outputs where output.path.hasPrefix(input.path) && output.path != input.path {
                    aliases[output.path] = source + output.path.dropFirst(input.path.count)
                }
            }
            for output in step.outputs where !output.path.hasPrefix("pipe:") {
                if let sha = output.sha256, !sha.isEmpty, producedEarlierByChecksum[sha] == nil {
                    producedEarlierByChecksum[sha] = output.path
                }
            }
        }
        func resolveAlias(_ path: String) -> String {
            var current = path
            var seen = Set<String>()
            while let next = aliases[current], seen.insert(current).inserted { current = next }
            return current
        }

        // 2. Rewrite the surviving steps: replay argv, staging decompression,
        //    bare executables, aliases.
        struct Draft {
            var numbers: [Int]
            var toolName: String
            /// One identity for each command. A pipe appends the identity of the stage it joins.
            var stageIdentities: [ProvenanceToolIdentityText]
            var kind: Kind
            var commands: [Command]
            var inputs: [FileRecord]
            var outputs: [FileRecord]
            var wallTime: TimeInterval?
            var isPlumbing: Bool
            var sources: [StepExecution]
            var ranUnder: Int?

            /// The first stage's identity, which pins the step's environment.
            var identity: ProvenanceToolIdentityText { stageIdentities[0] }
        }
        let survivors = numbered.filter { !collapsedNumbers.contains($0.number) }
        let subStepParents = Self.subStepParents(in: survivors, replayArguments: replayArguments)
        var drafts: [Draft] = []
        for (number, step) in numbered where !collapsedNumbers.contains(number) {
            var identity = ProvenanceToolIdentityText.parse(toolName: step.toolName, toolVersion: step.toolVersion)
            var toolName = step.toolName
            var kind: Kind
            var command: Command
            var isPlumbing = false
            if let decompression = Self.decompression(of: step) {
                command = decompression
                toolName = "gzip"
                identity = ProvenanceToolIdentityText.parse(toolName: "gzip", toolVersion: "system")
                kind = .tool
                isPlumbing = true
            } else if let argv = replayArguments(step), !argv.isEmpty {
                let normalized = Self.normalizeExecutable(argv, identity: &identity, toolName: toolName)
                // A classifier keeps its managed environment only in the step's runtime identity, which counts
                // when its executable is that environment's copy of this step's own program (lane P5b).
                if identity.environment == nil, let runtime = step.runtimeIdentity, let name = runtime.condaEnvironment,
                   let program = normalized.first.map({ URL(fileURLWithPath: $0).lastPathComponent }),
                   runtime.executablePath?.hasSuffix("/envs/\(name)/bin/\(program)") == true {
                    identity = ProvenanceToolIdentityText(
                        toolName: identity.toolName,
                        version: identity.version,
                        environment: ProvenanceManagedEnvironment(name: name, executable: program, packageSpec: nil),
                        runtimeNote: identity.runtimeNote
                    )
                }
                command = Command(argv: normalized, stdoutPath: nil)
                kind = Self.isInternal(step) || Self.namesRetiredHelper(argv) ? .inApp : (Self.isCLI(normalized) ? .wrapper : .tool)
            } else {
                command = Command(argv: step.durableReplayArgv ?? step.command, stdoutPath: nil)
                kind = .inApp
            }
            let aliased = Command(
                argv: command.argv.map { Self.replacingPaths(in: $0, using: resolveAlias) },
                stdoutPath: command.stdoutPath.map(resolveAlias)
            )
            drafts.append(Draft(
                numbers: [number],
                toolName: toolName,
                stageIdentities: [identity],
                kind: kind,
                commands: [aliased],
                inputs: step.inputs.map { $0.replacingPath(resolveAlias($0.path)) },
                outputs: step.outputs.map { $0.replacingPath(resolveAlias($0.path)) },
                wallTime: step.wallTime,
                isPlumbing: isPlumbing,
                sources: [step],
                ranUnder: subStepParents[number]
            ))
        }

        // 3. Join pipes.
        var merged: [Draft] = []
        var consumed = Set<Int>()
        for (index, draft) in drafts.enumerated() where !consumed.contains(index) {
            var current = draft
            var searchFrom = index + 1
            while let pipe = current.outputs.first(where: { $0.path.hasPrefix("pipe:") }),
                  let readerIndex = drafts.indices.dropFirst(searchFrom).first(where: { candidate in
                      !consumed.contains(candidate) && drafts[candidate].inputs.contains { $0.path == pipe.path }
                  }) {
                let reader = drafts[readerIndex]
                consumed.insert(readerIndex)
                current.numbers += reader.numbers
                current.stageIdentities += reader.stageIdentities
                current.commands += reader.commands
                current.inputs = Self.uniqueRecords(current.inputs + reader.inputs).filter { !$0.path.hasPrefix("pipe:") }
                current.outputs = Self.uniqueRecords(
                    current.outputs.filter { $0.path != pipe.path } + reader.outputs
                )
                current.wallTime = [current.wallTime, reader.wallTime].compactMap { $0 }.max()
                current.sources += reader.sources
                // A joined pipeline is a sub-step only when both of its ends are, of the same step.
                if current.ranUnder != reader.ranUnder { current.ranUnder = nil }
                if current.toolName != reader.toolName {
                    current.toolName += " | " + reader.toolName
                }
                current.kind = current.kind == .inApp || reader.kind == .inApp ? .inApp : current.kind
                searchFrom = readerIndex + 1
            }
            merged.append(current)
        }

        // 4. Map paths.
        let mapper = PathMapper(
            produced: Set(merged.flatMap { $0.outputs.map(\.path) }),
            allPaths: merged.flatMap { $0.inputs.map(\.path) + $0.outputs.map(\.path) + $0.commands.flatMap(\.argv) }
        )

        // 5. Pin each step's environment to a package. The plan keeps one entry for each package a
        //    tool step installed. A later package of an environment that already has one is a
        //    variant of it, so two steps that disagree keep both specs. A sub-step is not run by the
        //    export, so it adds no environment to create.
        func pinnedEnvironment(of draft: Draft) -> ProvenanceManagedEnvironment? {
            draft.identity.environment.map { Self.pinned($0, version: draft.identity.version, lock: lock) }
        }
        var environments: [ProvenanceManagedEnvironment] = []
        for draft in merged where draft.kind == .tool && draft.ranUnder == nil {
            guard let pinned = pinnedEnvironment(of: draft) else { continue }
            guard !environments.contains(where: { $0.name == pinned.name && $0.packageSpec == pinned.packageSpec }) else { continue }
            let variant = (environments.filter { $0.name == pinned.name }.map(\.variant).max() ?? 0) + 1
            environments.append(ProvenanceManagedEnvironment(
                name: pinned.name, executable: pinned.executable, packageSpec: pinned.packageSpec, variant: variant
            ))
        }

        self.steps = merged.map { draft in
            let pinned = pinnedEnvironment(of: draft)
            return Step(
                numbers: draft.numbers,
                toolName: draft.toolName,
                stageIdentities: draft.stageIdentities,
                environment: pinned.map { pinned in
                    environments.first { $0.name == pinned.name && $0.packageSpec == pinned.packageSpec } ?? pinned
                },
                kind: draft.kind,
                commands: draft.commands,
                inputs: draft.inputs,
                outputs: draft.outputs,
                wallTime: draft.wallTime,
                containerImage: draft.sources.first?.containerImage,
                containerDigest: draft.sources.first?.containerDigest,
                isSuccess: draft.sources.allSatisfy(\.isSuccess),
                isPlumbing: draft.isPlumbing,
                sourceSteps: draft.sources,
                ranUnder: draft.ranUnder
            )
        }
        self.collapsed = collapsed
        self.environments = environments
        self.projectRoots = mapper.projectRoots
        self.mapper = mapper
    }

    // MARK: - Paths

    func map(_ path: String) -> MappedPath {
        mapper.map(path)
    }

    /// `token` with every recorded path inside it spelt by `spell`.
    func rewrite(token: String, spell: (MappedPath) -> String) -> String {
        mapper.rewrite(token: token, spell: spell)
    }

    /// The command line of `step`: commands joined by ` | `, tokens spelt by
    /// `spell` and escaped by `escape`.
    func commandLine(
        for step: Step,
        spell: (MappedPath) -> String,
        escape: (String) -> String
    ) -> String {
        step.commands.map { command -> String in
            var line = command.argv.map { escape(rewrite(token: $0, spell: spell)) }.joined(separator: " ")
            if let stdoutPath = command.stdoutPath {
                line += " > " + escape(spell(map(stdoutPath)))
            }
            return line
        }.joined(separator: " | ")
    }

    /// Every step the executable exports run, in order. A sub-step is not one, its CLI step runs it.
    var replayableSteps: [Step] { steps.filter { $0.isReplayable && !$0.isSubStep } }

    /// Every in-app step the executable exports leave out, in order.
    var inAppSteps: [Step] { steps.filter { !$0.isReplayable && !$0.isSubStep } }

    /// Inputs of replayable steps that no earlier replayable step produced,
    /// once each by file name, in first-use order.
    var parameters: [Parameter] {
        var produced = Set<String>()
        var seen = Set<String>()
        var parameters: [Parameter] = []
        for step in replayableSteps {
            for input in step.inputs where !input.path.hasPrefix("pipe:") {
                let name = input.filename
                guard !produced.contains(name), seen.insert(name).inserted else { continue }
                parameters.append(Parameter(filename: name, path: map(input.path)))
            }
            for output in step.outputs {
                produced.insert(output.filename)
            }
        }
        return parameters
    }

    /// Files the external tools read that no step produced (by path or by
    /// checksum), once each: the run's true inputs. A sub-step also reads scratch files of its CLI
    /// step's workspace, which no command of the script reads, so only the inputs its CLI step lists
    /// too count.
    var primaryInputs: [FileRecord] {
        let produced = Set(steps.flatMap { $0.outputs.map(\.path) })
        var producedEarlierChecksums = Set<String>()
        var seen = Set<String>()
        var inputs: [FileRecord] = []
        for step in steps {
            let parentInputs = step.ranUnder.flatMap { n in steps.first { $0.numbers.contains(n) } }.map { Set($0.inputs.map(\.path)) }
            if step.kind == .tool {
                for record in step.inputs where !record.path.hasPrefix("pipe:")
                    && !produced.contains(record.path)
                    && !(record.sha256.map(producedEarlierChecksums.contains) ?? false)
                    && (parentInputs?.contains(record.path) ?? true)
                    && seen.insert("\(record.path)\u{0}\(record.sha256 ?? "")").inserted {
                    inputs.append(record)
                }
            }
            for output in step.outputs {
                if let sha = output.sha256 { producedEarlierChecksums.insert(sha) }
            }
        }
        return inputs
    }

    /// Recorded values still holding an `<external>` or `<workspace>` placeholder.
    var unresolvedPaths: [String] {
        let values = steps.filter { !$0.isSubStep }.flatMap { $0.commands.flatMap(\.argv) + $0.inputs.map(\.path) }
        return values.filter(PortablePath.containsUnresolvedPlaceholder)
    }

    // MARK: - Environments

    /// An environment with a package pin. A version other than the recorded one is never written.
    ///
    /// A recorded conda spec stays as recorded only at the recorded version. Otherwise the lock entry installed in
    /// the environment names the channel and the package, found through either lock list so a pack
    /// tool resolves. When the recorded version is the lock entry's version the plan writes the lock's
    /// spec with its build (`bioconda::whatshap=2.3=py311h1457a19_3` for `phasing` at 2.3). When the
    /// recorded version differs it writes the channel, the package and the recorded version with no
    /// build (`bioconda::kraken2=2.1.3`), because the lock cannot say which build of another version
    /// ran. A version that is no number, such as `unknown` or a probe error, writes the bare package,
    /// which pins nothing.
    ///
    /// A recorded package that is no conda spec, such as the `ivar` older records kept, pins nothing
    /// and gives way to the lock. An environment name is not a package name, so it stands in for the
    /// package only when the lock does not hold the environment. A Python runtime or a source build
    /// has no conda spec of its own, so the plan writes the tool's id at the recorded version and
    /// leaves the refusal to the pin gate.
    static func pinned(
        _ environment: ProvenanceManagedEnvironment,
        version: String,
        lock: ManagedToolLock = .bundled
    ) -> ProvenanceManagedEnvironment {
        func with(_ spec: String) -> ProvenanceManagedEnvironment {
            ProvenanceManagedEnvironment(
                name: environment.name, executable: environment.executable, packageSpec: spec, variant: environment.variant
            )
        }
        if let recorded = environment.packageSpec, let spec = CondaSpec(spec: recorded) {
            // A spec of another version is the lock the writer read, not what ran.
            if spec.version == version { return environment }
            if lock.entry(environment: environment.name) == nil {
                let channel = spec.channel.map { "\($0)::" } ?? ""
                return with(version.first?.isNumber == true ? "\(channel)\(spec.name)=\(version)" : spec.name)
            }
        }
        let numeric = version.first?.isNumber == true
        guard let entry = lock.entry(environment: environment.name) else {
            if environment.packageSpec != nil { return environment }
            return with(numeric ? "bioconda::\(environment.name)=\(version)" : environment.name)
        }
        guard let lockSpec = lock.packageSpec(of: entry), let locked = CondaSpec(spec: lockSpec) else {
            let package = entry.id.rawValue
            return with(numeric ? "bioconda::\(package)=\(version)" : package)
        }
        guard numeric else { return with(locked.name) }
        let channel = locked.channel.map { "\($0)::" } ?? ""
        if version == locked.version, let build = locked.build {
            return with("\(channel)\(locked.name)=\(version)=\(build)")
        }
        return with("\(channel)\(locked.name)=\(version)")
    }

    /// `bbmap` for the `bbtools` environment and `whatshap` for `phasing`, from the managed-tool lock
    /// (`bioconda::bbmap=40.02=he046917_0`). The entry is found by its environment through either
    /// lock list, and a tool a Python runtime or a source build installs is named by its id.
    static func lockPackageName(forEnvironment name: String, lock: ManagedToolLock = .bundled) -> String? {
        guard let entry = lock.entry(environment: name) else { return nil }
        guard let spec = lock.packageSpec(of: entry), let parsed = CondaSpec(spec: spec) else { return entry.id.rawValue }
        return parsed.name
    }

    // MARK: - Step shapes

    static func isInternal(_ step: StepExecution) -> Bool {
        (step.durableReplayArgv ?? step.command).first == "lungfish-internal"
    }

    /// The re-launch flags of the app's retired import helpers, the BAM helper and the metagenomics helper. Records
    /// written before Phase 2.12 name the BAM flag after the app's executable. Metagenomics records written before
    /// 2026-07-04 do the same, and later ones name `lungfish-cli import <kind>`. The app stops offering both flags in
    /// 2.12 (lane 12.06), so such a step is history, which the plan names and does not replay (BIO 4). New records
    /// name `lungfish-cli import bam` and `lungfish-cli import <kind>`.
    static let retiredHelperFlags: Set<String> = ["--bam-import-helper", "--metagenomics-import-helper"]

    /// The marker flags that a BAM import record appends to the argv of its two in-app steps, the clone of an already
    /// sorted BAM and the collection of alignment metadata (`BAMImportService+Provenance.swift`). No command accepts
    /// them, so a step that carries one is an in-app step whatever executable it names. Records that the `import bam`
    /// leaf or a default caller wrote name `lungfish-cli` there and older records name the retired helper.
    static let inAppMarkerFlags: Set<String> = ["--clone-sorted-alignment", "--collect-alignment-metadata"]

    static func namesRetiredHelper(_ argv: [String]) -> Bool {
        (argv.count >= 2 && retiredHelperFlags.contains(argv[1])) || argv.contains(where: inAppMarkerFlags.contains)
    }

    static func isCLI(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        return URL(fileURLWithPath: first).lastPathComponent == CLICommandIdentity.executableName
    }

    /// `lungfish-internal stage-reference --input X --output Y --mode decompress-gzip`
    /// as `gzip -dc X > Y`.
    private static func decompression(of step: StepExecution) -> Command? {
        let argv = step.command
        guard argv.count >= 2, argv[0] == "lungfish-internal", argv[1] == "stage-reference",
              value(of: "--mode", in: argv) == "decompress-gzip",
              let input = value(of: "--input", in: argv),
              let output = value(of: "--output", in: argv) else { return nil }
        return Command(argv: ["gzip", "-dc", input], stdoutPath: output)
    }

    private static func value(of flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    /// A managed executable spelt bare, its environment kept: an absolute
    /// argv[0] whose file name is the tool, and a `micromamba run -n X`
    /// prefix.
    private static func normalizeExecutable(
        _ argv: [String],
        identity: inout ProvenanceToolIdentityText,
        toolName: String
    ) -> [String] {
        var argv = argv
        if argv.count >= 5, argv[0] == "micromamba", argv[1] == "run", argv[2] == "-n" {
            let environment = argv[3]
            argv.removeFirst(4)
            if identity.environment == nil {
                identity = ProvenanceToolIdentityText(
                    toolName: identity.toolName,
                    version: identity.version,
                    environment: ProvenanceManagedEnvironment(name: environment, executable: argv.first, packageSpec: nil),
                    runtimeNote: identity.runtimeNote
                )
            }
        }
        guard let executable = argv.first, executable.hasPrefix("/") || executable.hasPrefix("<") else { return argv }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let expected = [identity.environment?.executable, toolName].compactMap { $0?.lowercased() }
        let managedEnvironment = managedEnvironmentName(in: executable)
        guard expected.contains(name.lowercased()) || managedEnvironment != nil else { return argv }
        argv[0] = name
        if identity.environment == nil, let managedEnvironment {
            identity = ProvenanceToolIdentityText(
                toolName: identity.toolName,
                version: identity.version,
                environment: ProvenanceManagedEnvironment(name: managedEnvironment, executable: name, packageSpec: nil),
                runtimeNote: identity.runtimeNote
            )
        }
        return argv
    }

    /// `samtools` for `.../envs/samtools/bin/samtools`.
    private static func managedEnvironmentName(in executable: String) -> String? {
        let components = executable.split(separator: "/").map(String.init)
        guard let bin = components.lastIndex(of: "bin"), bin >= 2, components[bin - 2] == "envs" else { return nil }
        return components[bin - 1]
    }

    private static func replacingPaths(in token: String, using transform: (String) -> String) -> String {
        if token.hasPrefix("/") || token.hasPrefix("<") || token.hasPrefix("@/") {
            return transform(token)
        }
        return token
    }

    private static func uniqueRecords(_ records: [FileRecord]) -> [FileRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted }
    }

    // MARK: - PathMapper

    struct PathMapper {
        let projectRoots: [String]
        private let produced: Set<String>
        /// Recorded absolute paths, longest first, for rewriting inside tokens.
        private let knownPaths: [String]
        /// Result file names that several scratch paths share.
        private let ambiguousResultNames: Set<String>

        init(produced: Set<String>, allPaths: [String]) {
            var roots: [String] = []
            var known: [String] = []
            for value in allPaths {
                for path in Self.absolutePaths(in: value) {
                    if !known.contains(path) { known.append(path) }
                    if let root = Self.projectRoot(of: path), !roots.contains(root) { roots.append(root) }
                }
            }
            self.projectRoots = roots
            self.produced = produced
            self.knownPaths = known.sorted { $0.count > $1.count }
            var namesToPaths: [String: Set<String>] = [:]
            for path in produced where Self.projectRoot(of: path) == nil {
                namesToPaths[URL(fileURLWithPath: path).lastPathComponent, default: []].insert(path)
            }
            self.ambiguousResultNames = Set(namesToPaths.filter { $0.value.count > 1 }.keys)
        }

        func map(_ path: String) -> MappedPath {
            if path.hasPrefix("pipe:") || path.isEmpty { return .verbatim(path) }
            // A relative recorded path is left as the tool wrote it.
            if !path.hasPrefix("/") && !path.hasPrefix("<") && !path.hasPrefix(PortablePath.projectPrefix) {
                return .verbatim(path)
            }
            if path.hasPrefix(PortablePath.projectPrefix) {
                return .project(String(path.dropFirst(PortablePath.projectPrefix.count)))
            }
            if let root = Self.projectRoot(of: path) {
                let tail = String(path.dropFirst(root.count))
                return .project(tail.hasPrefix("/") ? String(tail.dropFirst()) : tail)
            }
            let url = URL(fileURLWithPath: path)
            if produced.contains(path) || path.hasPrefix(PortablePath.workspacePlaceholder) {
                let name = url.lastPathComponent
                if ambiguousResultNames.contains(name) {
                    return .result("results/\(url.deletingLastPathComponent().lastPathComponent)/\(name)")
                }
                return .result("results/\(name)")
            }
            return .external(path)
        }

        func rewrite(token: String, spell: (MappedPath) -> String) -> String {
            if token.hasPrefix("/") || token.hasPrefix("<") || token.hasPrefix("@/") {
                return spell(map(token))
            }
            guard token.contains("/") else { return token }
            var result = token
            for path in knownPaths where result.contains(path) {
                result = result.replacingOccurrences(of: path, with: spell(map(path)))
            }
            return result
        }

        /// The `.lungfish` project root a recorded path lies under, if any.
        static func projectRoot(of path: String) -> String? {
            var current = path
            while current.count > 1 {
                if current.lowercased().hasSuffix(".lungfish") { return current }
                let parent = (current as NSString).deletingLastPathComponent
                guard parent != current, !parent.isEmpty else { return nil }
                current = parent
            }
            return nil
        }

        /// The whole value when it is one path, else each `/...` span up to
        /// a terminator or an `=` boundary (`in=/data/reads.fq`).
        private static func absolutePaths(in value: String) -> [String] {
            if PortablePath.isSingleAbsolutePath(value) { return [value] }
            guard value.contains("/") else { return [] }
            var paths: [String] = []
            var current = ""
            var inPath = false
            var previous: Character?
            for character in value {
                let leadsIn = previous == nil || previous == " " || previous == "=" || previous == "'" || previous == "\""
                if character == "/" && !inPath && leadsIn {
                    inPath = true
                    current = "/"
                } else if inPath {
                    if character == " " || character == "," || character == ";" || character == "'" || character == "\"" {
                        if current.count > 1 { paths.append(current) }
                        inPath = false
                        current = ""
                    } else {
                        current.append(character)
                    }
                }
                previous = character
            }
            if inPath, current.count > 1 { paths.append(current) }
            return paths.filter { $0.dropFirst().contains("/") }
        }
    }
}

private extension FileRecord {
    func replacingPath(_ path: String) -> FileRecord {
        FileRecord(path: path, sha256: sha256, sizeBytes: sizeBytes, format: format, role: role)
    }
}
