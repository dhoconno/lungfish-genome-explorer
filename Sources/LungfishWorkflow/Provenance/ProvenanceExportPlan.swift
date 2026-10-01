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
//   pipeline;
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
        let identity: ProvenanceToolIdentityText
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

        var number: Int { numbers[0] }
        var isReplayable: Bool { kind != .inApp }
        var environment: ProvenanceManagedEnvironment? {
            identity.environment.map { ProvenanceExportPlan.pinned($0, version: identity.version) }
        }

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
    let environments: [ProvenanceManagedEnvironment]
    /// Every recorded `.lungfish` project root seen, as recorded.
    let projectRoots: [String]
    private let mapper: PathMapper

    /// The plan of `run`. `replayArguments` selects each step's replay argv
    /// and returns nil for a step that has none (a GUI action).
    init(run: WorkflowRun, replayArguments: (StepExecution) -> [String]?) {
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
            var identity: ProvenanceToolIdentityText
            var kind: Kind
            var commands: [Command]
            var inputs: [FileRecord]
            var outputs: [FileRecord]
            var wallTime: TimeInterval?
            var isPlumbing: Bool
            var sources: [StepExecution]
        }
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
                command = Command(argv: normalized, stdoutPath: nil)
                kind = Self.isInternal(step) ? .inApp : (Self.isCLI(normalized) ? .wrapper : .tool)
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
                identity: identity,
                kind: kind,
                commands: [aliased],
                inputs: step.inputs.map { $0.replacingPath(resolveAlias($0.path)) },
                outputs: step.outputs.map { $0.replacingPath(resolveAlias($0.path)) },
                wallTime: step.wallTime,
                isPlumbing: isPlumbing,
                sources: [step]
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
                current.commands += reader.commands
                current.inputs = Self.uniqueRecords(current.inputs + reader.inputs).filter { !$0.path.hasPrefix("pipe:") }
                current.outputs = Self.uniqueRecords(
                    current.outputs.filter { $0.path != pipe.path } + reader.outputs
                )
                current.wallTime = [current.wallTime, reader.wallTime].compactMap { $0 }.max()
                current.sources += reader.sources
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

        self.steps = merged.map { draft in
            Step(
                numbers: draft.numbers,
                toolName: draft.toolName,
                identity: draft.identity,
                kind: draft.kind,
                commands: draft.commands,
                inputs: draft.inputs,
                outputs: draft.outputs,
                wallTime: draft.wallTime,
                containerImage: draft.sources.first?.containerImage,
                containerDigest: draft.sources.first?.containerDigest,
                isSuccess: draft.sources.allSatisfy(\.isSuccess),
                isPlumbing: draft.isPlumbing,
                sourceSteps: draft.sources
            )
        }
        self.collapsed = collapsed
        var environments: [ProvenanceManagedEnvironment] = []
        for step in steps where step.kind == .tool {
            guard let environment = step.environment.map({ Self.pinned($0, version: step.identity.version) }) else { continue }
            if let index = environments.firstIndex(where: { $0.name == environment.name }) {
                if environments[index].packageSpec == nil, environment.packageSpec != nil {
                    environments[index] = environment
                }
            } else {
                environments.append(environment)
            }
        }
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

    /// Every step the executable exports run, in order.
    var replayableSteps: [Step] { steps.filter(\.isReplayable) }

    /// Every in-app step the executable exports leave out, in order.
    var inAppSteps: [Step] { steps.filter { !$0.isReplayable } }

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
    /// checksum), once each: the run's true inputs.
    var primaryInputs: [FileRecord] {
        let produced = Set(steps.flatMap { $0.outputs.map(\.path) })
        var producedEarlierChecksums = Set<String>()
        var seen = Set<String>()
        var inputs: [FileRecord] = []
        for step in steps {
            if step.kind == .tool {
                for record in step.inputs where !record.path.hasPrefix("pipe:")
                    && !produced.contains(record.path)
                    && !(record.sha256.map(producedEarlierChecksums.contains) ?? false)
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
        let values = steps.flatMap { $0.commands.flatMap(\.argv) + $0.inputs.map(\.path) }
        return values.filter(PortablePath.containsUnresolvedPlaceholder)
    }

    // MARK: - Environments

    /// An environment with a package pin: the recorded pin, or the package
    /// the managed lock installs for that environment at the recorded
    /// version (`bioconda::bbmap=40.02` for `bbtools` v40.02). An
    /// environment name is not a package name, so an unpinned environment
    /// is never emitted as one.
    static func pinned(_ environment: ProvenanceManagedEnvironment, version: String) -> ProvenanceManagedEnvironment {
        guard environment.packageSpec == nil else { return environment }
        let package = lockPackageName(forEnvironment: environment.name) ?? environment.name
        let spec = version.first?.isNumber == true ? "bioconda::\(package)=\(version)" : package
        return ProvenanceManagedEnvironment(name: environment.name, executable: environment.executable, packageSpec: spec)
    }

    /// `bbmap` for the `bbtools` environment, from the bundled managed-tool
    /// lock (`bioconda::bbmap=39.33=h92535d8_0`).
    private static func lockPackageName(forEnvironment name: String) -> String? {
        guard let spec = try? ManagedToolLock.loadFromBundle().tool(named: name)?.packageSpec else { return nil }
        var package = spec
        if let channel = package.range(of: "::") { package = String(package[channel.upperBound...]) }
        if let version = package.firstIndex(of: "=") { package = String(package[..<version]) }
        let trimmed = package.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Step shapes

    private static let guiNames = ["lungfish.app", "lungfish-app", "lungfish-gui", "lungfish genome explorer"]

    static func isInternal(_ step: StepExecution) -> Bool {
        (step.durableReplayArgv ?? step.command).first == "lungfish-internal"
    }

    private static func isCLI(_ argv: [String]) -> Bool {
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
