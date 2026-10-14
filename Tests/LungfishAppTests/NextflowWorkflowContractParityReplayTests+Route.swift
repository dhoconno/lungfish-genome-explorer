// NextflowWorkflowContractParityReplayTests+Route.swift - One run of today's Viral Recon route and what it left
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q33 M2. Runs `lungfish-cli workflow run nf-core/viralrecon` as a separate process on a stand-in of
// its own, and reads back the launches, the project's tree and the records with what differs between runs masked.

import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

/// What one run of `workflow run` left.
struct ViralReconRouteRun {
    let status: Int32
    let stderr: String
    let launches: [NextflowStandInEngine.Launch]
    /// Every path under the project, folders with a trailing slash, masked.
    let tree: [String]
    /// Every JSON file under the project, as canonical JSON with what differs between runs masked.
    let records: String
    /// `<record> <key>` of each checksum and size a record states for a folder, which differ between any two roots.
    let digestGapCandidates: [String]
    let spawnEnvironment: [String: String]
    let cliFolder: String
    let normalizer: ViralReconRouteNormalizer
    /// The status, standard error, argv, added environment, tree, digest gap and records as one text, which the
    /// case's fixture pins.
    var observed = ""

    func normalize(_ text: String) -> String { normalizer.normalize(text) }

    /// The launch's environment beyond the CLI's own, as `KEY=value` lines. The shell's own variables are left out,
    /// and PATH keeps the folders LGE puts ahead of the CLI's PATH. The Docker stand-in's variable is listed when the
    /// launch inherits it, so the fixture shows what reaches Nextflow from the test's seam (Q33 R4).
    func addedEnvironment(_ launch: NextflowStandInEngine.Launch) -> String {
        let shell: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
        let seam = NextflowWorkflowContractParityReplayTests.dockerStandInVariable
        return launch.environment.keys.sorted().compactMap { key -> String? in
            guard let value = launch.environment[key], !shell.contains(key), key == seam || spawnEnvironment[key] != value else { return nil }
            guard key == "PATH" else { return "\(key)=\(normalize(value))" }
            let kept = value.split(separator: ":").map(String.init).prefix { $0 != cliFolder }
            return "PATH=" + normalize((kept + ["<the CLI's PATH>"]).joined(separator: ":"))
        }.joined(separator: "\n")
    }
}

/// Masks the case root, the launch scratch, times, UUIDs and the CLI's version.
struct ViralReconRouteNormalizer: Sendable {
    let caseRoot: URL
    let scratch: String?
    let cliVersion: String

    func normalize(_ text: String) -> String {
        var masked = text
        let candidates: [(String, String)?] = [
            scratch.map { ($0, "<scratch>") }, (caseRoot.path, "<root>"),
            (ProvenanceCompatCorpus.repositoryRoot.path, "<repository>"),
        ]
        let roots = candidates.compactMap { $0 }
        for (path, placeholder) in roots {
            for form in ["/private" + path, path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] {
                masked = masked.replacingOccurrences(of: form, with: placeholder)
            }
        }
        if !cliVersion.isEmpty { masked = masked.replacingOccurrences(of: "\"\(cliVersion)\"", with: "\"<cli version>\"") }
        let rules = [
            (#"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})"#, "<time>"),
            (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<uuid>"),
        ]
        for (pattern, replacement) in rules {
            if let regex = try? Regex(pattern) { masked = masked.replacing(regex, with: replacement) }
        }
        return masked
    }
}

/// Reads every JSON file under a project as canonical JSON and masks what differs between runs. That is times,
/// durations, host and build facts, and the checksum and size a record states for any file in the project, whose
/// bytes are the stand-in's or name the run's root. It is wider than the contract's Masks, which keep a byte-compared
/// file's checksum, because this class pins one run's records against a fixture and compares no payload's bytes. A
/// folder's checksum and size are masked only when `digestGap` names them.
enum ViralReconRouteRecords {
    static func read(
        project: URL, normalizer: ViralReconRouteNormalizer, digestGap: Set<String>
    ) throws -> (tree: [String], records: String, candidates: [String]) {
        var tree: [String] = []
        var jsonFiles: [(String, URL)] = []
        let base = project.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([], "", [])
        }
        for case let url as URL in enumerator {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            tree.append(normalizer.normalize(relative) + (isDirectory ? "/" : ""))
            if !isDirectory, url.pathExtension == "json" { jsonFiles.append((relative, url)) }
        }
        var records: [String] = []
        var candidates: [String] = []
        for (relative, url) in jsonFiles.sorted(by: { $0.0 < $1.0 }) {
            let name = normalizer.normalize(relative)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
            let masked = mask(object, keyPath: "", record: name, normalizer: normalizer, digestGap: digestGap, candidates: &candidates)
            let data = try JSONSerialization.data(withJSONObject: masked, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            records.append("== \(name)\n" + normalizer.normalize(String(decoding: data, as: UTF8.self)))
        }
        return (tree.sorted(), records.joined(separator: "\n"), candidates.sorted())
    }

    private static let durationKeys = ["walltime", "duration", "elapsed"]
    /// Facts of the host and of LGE's build, which the contract masks with the host (CLI-EQUIVALENCE.md, Masks).
    private static let hostKeys: Set<String> = [
        "hostname", "host", "pid", "processidentifier", "username", "user", "appversion", "operatingsystemversion", "architecture",
    ]

    private static func mask(
        _ value: Any, keyPath: String, record: String, normalizer: ViralReconRouteNormalizer,
        digestGap: Set<String>, candidates: inout [String]
    ) -> Any {
        if let array = value as? [Any] {
            return array.enumerated().map { index, element in
                mask(element, keyPath: "\(keyPath)[\(index)]", record: record, normalizer: normalizer, digestGap: digestGap, candidates: &candidates)
            }
        }
        guard var dictionary = value as? [String: Any] else { return value }
        let path = ["path", "url", "filePath"].compactMap { dictionary[$0] as? String }.first
        var isDirectory: ObjCBool = false
        let inProject = path.map { normalizer.normalize($0).hasPrefix("<root>/") } ?? false
        if let path, inProject { _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) }
        for key in dictionary.keys.sorted() {
            let child = keyPath.isEmpty ? key : "\(keyPath).\(key)"
            let lowered = key.lowercased()
            let isDigest = lowered.contains("sha256") || lowered.contains("checksum") || lowered == "size" || lowered == "sizebytes" || lowered == "filesize"
            if isDigest, inProject {
                if isDirectory.boolValue {
                    candidates.append("\(record) \(child)")
                    if digestGap.contains("\(record) \(child)") { dictionary[key] = "<digest gap>" }
                } else {
                    dictionary[key] = "<masked \(lowered.contains("size") ? "size" : "checksum")>"
                }
            } else if durationKeys.contains(where: lowered.contains), dictionary[key] is NSNumber {
                dictionary[key] = "<seconds>"
            } else if hostKeys.contains(lowered) || (dictionary[key] as? String)?.hasPrefix("Lungfish 20") == true {
                dictionary[key] = "<\(lowered)>"
            } else if let nested = dictionary[key] {
                dictionary[key] = mask(nested, keyPath: child, record: record, normalizer: normalizer, digestGap: digestGap, candidates: &candidates)
            }
        }
        return dictionary
    }
}

extension NextflowWorkflowContractParityReplayTests {
    /// Runs `workflow run nf-core/viralrecon` with `executor` through the built CLI, or `cli`, on a stand-in of its
    /// own in `root/<case>`. The command is the one the app records for one paired Illumina amplicon sample of the
    /// nf-core/test-datasets reads, with the wizard's default skips and two CPUs.
    func runRoute(
        _ executor: NFCoreExecutor, case name: String, cli: URL? = nil, passesVersion: Bool = true,
        behaviour: NextflowStandInEngine.Behaviour = .completes
    ) throws -> ViralReconRouteRun {
        let cli = try cli ?? builtCLI()
        try requireDockerStandInReader(cli)
        let caseRoot = root.appendingPathComponent(name, isDirectory: true)
        let (engine, arguments, environment) = try routeCommand(executor, caseRoot: caseRoot, passesVersion: passesVersion, behaviour: behaviour)
        let result = try ProcessRunner.run(cli, arguments, environment: environment, cwd: caseRoot.appendingPathComponent("Project"), timeout: 120)
        let launches = try engine.launches()
        var spawn = ProcessInfo.processInfo.environment
        spawn["PATH"] = cli.deletingLastPathComponent().path + ":" + (spawn["PATH"] ?? "/usr/bin:/bin")
        spawn.merge(environment) { _, new in new }
        let version = (try? ProcessRunner.run(cli, ["--version"], timeout: 60).stdout)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizer = ViralReconRouteNormalizer(
            caseRoot: caseRoot,
            scratch: launches.first?.workDirectory.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
            cliVersion: version)
        let read = try ViralReconRouteRecords.read(
            project: caseRoot.appendingPathComponent("Project", isDirectory: true), normalizer: normalizer,
            digestGap: Set(Self.digestGap.map { "\($0.record) \($0.key)" }))
        var run = ViralReconRouteRun(
            status: result.status, stderr: result.stderr, launches: launches, tree: read.tree, records: read.records,
            digestGapCandidates: read.candidates, spawnEnvironment: spawn, cliFolder: cli.deletingLastPathComponent().path,
            normalizer: normalizer)
        run.observed = [
            "status \(run.status)", "stderr:\n" + run.normalize(run.stderr),
            "argv:\n" + launches.map { run.normalize($0.arguments.joined(separator: "\n")) }.joined(separator: "\n--\n"),
            "environment:\n" + launches.map(run.addedEnvironment).joined(separator: "\n--\n"),
            "tree:\n" + run.tree.joined(separator: "\n"), "digest gap:\n" + run.digestGapCandidates.joined(separator: "\n"),
            "records:\n" + run.records,
        ].joined(separator: "\n\n") + "\n"
        dump(run.observed, as: name)
        return run
    }

    /// The stand-in of a case in `caseRoot/engine` with `behaviour`, and the command and environment of the run the
    /// app records for one paired Illumina amplicon sample, which `runRoute` and a cancel case start in
    /// `caseRoot/Project`.
    func routeCommand(
        _ executor: NFCoreExecutor, caseRoot: URL, passesVersion: Bool = true,
        behaviour: NextflowStandInEngine.Behaviour = .completes
    ) throws -> (engine: NextflowStandInEngine, arguments: [String], environment: [String: String]) {
        let engine = try NextflowStandInEngine(
            root: caseRoot.appendingPathComponent("engine", isDirectory: true), workflow: .viralRecon, behaviour: behaviour)
        engines.append(engine)
        let analyses = caseRoot.appendingPathComponent("Project/Analyses", isDirectory: true)
        let reads = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        let sample = ViralReconSample(
            sampleName: "S1", sourceBundleURL: reads,
            fastqURLs: [reads.appendingPathComponent("test_1.fastq.gz"), reads.appendingPathComponent("test_2.fastq.gz")],
            barcode: nil, sequencingSummaryURL: nil)
        let request = try ViralReconRunRequest(
            samples: [sample], platform: .illumina, protocol: .amplicon,
            samplesheetURL: try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: [sample], in: analyses.appendingPathComponent(".viralrecon-inputs", isDirectory: true)),
            outputDirectory: analyses.appendingPathComponent("viralrecon-results", isDirectory: true),
            executor: executor, version: "3.0.0", reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: reads, displayName: "test", bedURL: reads.appendingPathComponent("test.bed"), fastaURL: nil,
                leftSuffix: "_LEFT", rightSuffix: "_RIGHT", derivedFasta: false),
            minimumMappedReads: 1, variantCaller: .ivar, consensusCaller: .bcftools,
            skipOptions: ViralReconSkipOption.defaultSelection.sorted { $0.rawValue < $1.rawValue },
            advancedParams: ["max_cpus": "2", "max_memory": "4.GB"])
        var arguments = request.cliArguments(bundlePath: analyses.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true))
        if !passesVersion, let index = arguments.firstIndex(of: "--version") {
            arguments.removeSubrange(index...(index + 1))
        }
        let environment = [
            "LUNGFISH_CONDA_ROOT": engine.condaRoot.path,
            "LUNGFISH_STORAGE_ROOT": caseRoot.appendingPathComponent("storage", isDirectory: true).path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": engine.home.path,
            Self.dockerStandInVariable: try Self.writeDockerStandIn(in: caseRoot).path,
        ]
        return (engine, arguments, environment)
    }

    /// The variable that points the built CLI's Docker wait and container cleanup at a stand-in (Q33 R4).
    static let dockerStandInVariable = "LUNGFISH_DOCKER_STANDIN"

    /// Writes `caseRoot/docker-standin/docker`, which stands in for the `docker` CLI and for `open -g -a Docker`. It
    /// appends each call's arguments to `calls.txt` beside it, answers `version` as a daemon that runs, or exits 1 as
    /// a stopped daemon does when a `daemon-down` file sits beside it, prints `ps.txt` for `ps` and `inspect.txt` for
    /// `inspect`, takes `kill` and `rm`, and refuses anything else, the call that would start Docker Desktop among
    /// them.
    static func writeDockerStandIn(in caseRoot: URL) throws -> URL {
        let folder = caseRoot.appendingPathComponent("docker-standin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("docker")
        try """
        #!/bin/sh
        here=$(dirname "$0")
        echo "$*" >> "$here/calls.txt"
        case "$1" in
          version) [ -e "$here/daemon-down" ] && exit 1; echo '28.3.2|28.3.2' ;;
          ps) cat "$here/ps.txt" 2>/dev/null ;;
          inspect) cat "$here/inspect.txt" 2>/dev/null ;;
          kill|rm) ;;
          *) exit 1 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Each call the case's Docker stand-in took, in order.
    func dockerStandInCalls(case name: String) -> [String] {
        let calls = root.appendingPathComponent("\(name)/docker-standin/calls.txt")
        return ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The built `lungfish-cli` beside the test bundle, or the one LUNGFISH_CLI_PATH names.
    func builtCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products) else {
            XCTFail("No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
            throw ParityError.missingCLI
        }
        return cli
    }

    /// Refuses a CLI that would not read the Docker stand-in, so no case reaches the real daemon (SWIFT's ruling on
    /// A30 deviation 2). Only a Debug build reads ``dockerStandInVariable``, so the CLI must be the file built beside
    /// this test bundle, the hard link of ``copyOfTheCLIWithoutThePin()`` included, and a release test build refuses
    /// every CLI. A CLI that `LUNGFISH_CLI_PATH` or the resolver's other variables name is another file.
    func requireDockerStandInReader(_ cli: URL) throws {
        #if DEBUG
        let beside = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lungfish-cli")
        func identity(_ url: URL) -> [Int]? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
                  let device = (attributes[.systemNumber] as? NSNumber)?.intValue,
                  let file = (attributes[.systemFileNumber] as? NSNumber)?.intValue
            else { return nil }
            return [device, file]
        }
        if let built = identity(beside), identity(cli) == built { return }
        #endif
        throw ParityError.cliIgnoresDockerStandIn(variable: Self.dockerStandInVariable)
    }

    /// A hard link of the built CLI in a folder of its own, beside links to its resource bundles, except that the
    /// workflow bundle's lock holds no `nf-core-viralrecon` pin. The CLI finds its resources beside its own path.
    func copyOfTheCLIWithoutThePin() throws -> URL {
        let cli = try builtCLI()
        let products = cli.deletingLastPathComponent()
        let folder = root.appendingPathComponent("cli-without-pin", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = ["LungfishGenomeBrowser_LungfishWorkflow.bundle", "Contents", "Resources", "ManagedTools", "third-party-tools-lock.json"]
        func mirror(_ source: URL, _ destination: URL, _ remaining: ArraySlice<String>) throws {
            guard let next = remaining.first else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
                for (key, entries) in object {
                    if let entries = entries as? [[String: Any]] {
                        object[key] = entries.filter { $0["id"] as? String != "nf-core-viralrecon" }
                    }
                }
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
                return
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(atPath: source.path) where item != next {
                try fileManager.createSymbolicLink(at: destination.appendingPathComponent(item), withDestinationURL: source.appendingPathComponent(item))
            }
            try mirror(source.appendingPathComponent(next), destination.appendingPathComponent(next), remaining.dropFirst())
        }
        for item in try fileManager.contentsOfDirectory(atPath: products.path) where item.hasSuffix(".bundle") && item != lock[0] {
            try fileManager.createSymbolicLink(at: folder.appendingPathComponent(item), withDestinationURL: products.appendingPathComponent(item))
        }
        try mirror(products.appendingPathComponent(lock[0]), folder.appendingPathComponent(lock[0]), lock.dropFirst())
        let copy = folder.appendingPathComponent("lungfish-cli")
        try fileManager.linkItem(at: cli, to: copy)
        return copy
    }

    /// Writes `text` to `<LUNGFISH_PARITY_DUMP>/<name>.txt` when that variable names a folder.
    func dump(_ text: String, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? line.write(to: url.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
