// NextflowDockerContainerCleanup.swift - Stops a cancelled Nextflow run's Docker task containers, found by their mounts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S10, panel decision N5 (option (c) of question Q-S1) with the manager's order ruling, and the
// SWIFT review's rule 6.

import Darwin
import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "NextflowContainerCleanup")

extension NextflowEngineProcess {
    /// The container cleanup of a run on this engine, or nil when its launch runs no task in Docker (N5).
    ///
    /// A launch whose effective profile runs its tasks in Docker gets ``NextflowDockerContainerCleanup``, which asks
    /// `probe`, the probe the engine's Docker wait asks, for the `docker` CLI only once a cancel needs it, so a run
    /// that is not cancelled starts no extra process. A conda run and a stand-in run get none, so their cancel
    /// stops the host tree alone.
    package func containerCleanup(probe: any ContainerRuntimeProbing) -> (any NextflowContainerCleanup)? {
        guard configuration.waitsForDocker else { return nil }
        return NextflowDockerContainerCleanup(probe: probe)
    }
}

/// Stops the Docker task containers of a cancelled Nextflow run once its host tree is gone (N5).
///
/// Nextflow labels no container, and a task's wrapper stops and removes its own container only while the
/// wrapper runs, so a run whose tree was killed leaves its containers running for up to 10 s and then behind
/// (Q15 R3). Every task container mounts its task folder, which lies inside the run's work folder. So the cleanup
///
/// 1. lists every container with `docker ps --all --quiet --no-trunc`,
/// 2. reads the state and the mounts of each with `docker inspect`,
/// 3. keeps the containers with a mount whose host side is the work folder or lies inside it, compared by whole
///    path components after resolving links (``containers(_:mountingInside:)``),
/// 4. kills the running ones with `docker kill`, and
/// 5. removes all of them with `docker rm`, as each task's wrapper would have.
///
/// `docker ps` has no filter that matches a mount by a folder that holds it, since its `volume` filter compares a
/// mount's whole source, so the match is made here. No container is chosen by its name, and a mount of a folder
/// that only holds the work folder, such as the system temporary folder every task mounts, never counts, so
/// another run's containers, a user's own among them, are never touched.
///
/// Each command runs through ToolProcess with its arguments as a list, every id an argument of its own, and with
/// what is left of the bound as its timeout. A command that cannot run, fails, times out or is cancelled ends the
/// cleanup with a log line, so the caller's record never waits past the bound.
package struct NextflowDockerContainerCleanup: NextflowContainerCleanup {
    /// The listing, every container, running or not, by its full id.
    package static let listArguments = ["ps", "--all", "--quiet", "--no-trunc"]
    /// The line `docker inspect` prints for each container, its full id, its state and its mounts as JSON.
    package static let inspectFormat = "{{.Id}}|{{.State.Status}}|{{json .Mounts}}"

    /// How much of a command's output is kept. A thousand containers print under 2 MB.
    private static let outputLimit = 16 * 1024 * 1024
    /// The grace a `docker` command stopped at the bound gets before KILL, and the time its output gets to end.
    private static let stopGrace: Duration = .milliseconds(200)

    /// Finds the `docker` CLI, asked only once a cancel needs it.
    private let locate: @Sendable () -> URL?

    /// A cleanup that runs `docker`.
    package init(docker: URL) {
        locate = { docker }
    }

    /// A cleanup that asks `probe` for the `docker` CLI once a cancel needs it.
    package init(probe: any ContainerRuntimeProbing) {
        locate = { probe.dockerCLIPath().map { URL(fileURLWithPath: $0) } }
    }

    /// The `docker` CLI the cleanup runs, or nil when none is installed.
    package func dockerExecutable() -> URL? {
        locate()
    }

    package func stopContainers(boundTo workDirectory: URL, within bound: Duration) async {
        let deadline = ContinuousClock().now.advanced(by: bound)
        guard let docker = locate() else {
            logger.warning("No docker CLI was found, so no container of the cancelled run was stopped")
            return
        }
        let run = { (arguments: [String]) in await Self.run(docker, arguments, before: deadline) }
        guard let listing = await run(Self.listArguments) else { return }
        guard listing.termination == .exited(code: 0) else {
            logger.warning(
                "docker ps exited \(listing.status): \(Self.firstLine(of: listing.stderrText), privacy: .public). No container was stopped."
            )
            return
        }
        let ids = Self.containerIDs(in: listing.stdoutText)
        guard !ids.isEmpty else { return }
        // A container that ended between `ps` and `inspect` makes `inspect` exit 1 after it printed the others.
        guard let inspected = await run(Self.inspectArguments(for: ids)) else { return }
        let owned = Self.containers(Self.parseInspect(inspected.stdoutText), mountingInside: workDirectory)
        guard !owned.isEmpty else {
            logger.info("No container of the cancelled run mounts \(workDirectory.path, privacy: .public)")
            return
        }
        let running = owned.filter(\.isRunning).map(\.id)
        if !running.isEmpty {
            guard let killed = await run(["kill"] + running) else { return }
            Self.log(killed, of: "kill", ids: running)
        }
        guard let removed = await run(["rm"] + owned.map(\.id)) else { return }
        Self.log(removed, of: "rm", ids: owned.map(\.id))
    }

    /// The `inspect` arguments for `ids`, each id an argument of its own.
    package static func inspectArguments(for ids: [String]) -> [String] {
        ["inspect", "--type", "container", "--format", inspectFormat] + ids
    }

    /// Runs `docker` with `arguments` and what is left before `deadline` as its timeout, or returns nil, with a log
    /// line, when no time is left or the command cannot run, times out or is cancelled.
    private static func run(
        _ docker: URL,
        _ arguments: [String],
        before deadline: ContinuousClock.Instant
    ) async -> ToolProcessResult? {
        let command = arguments.first ?? ""
        let left = deadline - ContinuousClock().now
        guard left > .zero else {
            logger.warning("The container cleanup ran out of its bound before docker \(command, privacy: .public)")
            return nil
        }
        let spec = ToolProcessSpec(
            executableURL: docker,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: .capture(limit: Self.outputLimit),
            stderr: .capture(limit: Self.outputLimit),
            timeout: left,
            terminationGracePeriod: Self.stopGrace,
            drainGracePeriod: Self.stopGrace,
            label: "docker \(command)"
        )
        do {
            return try await ToolProcess.run(spec)
        } catch {
            logger.warning(
                "docker \(command, privacy: .public) did not finish: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func log(_ result: ToolProcessResult, of command: String, ids: [String]) {
        let names = ids.map { String($0.prefix(12)) }.joined(separator: " ")
        if result.termination == .exited(code: 0) {
            logger.info("docker \(command, privacy: .public) of the cancelled run's containers \(names, privacy: .public)")
        } else {
            logger.warning(
                "docker \(command, privacy: .public) of \(names, privacy: .public) exited \(result.status): \(firstLine(of: result.stderrText), privacy: .public)"
            )
        }
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
    }
}

// MARK: - Reading and matching

/// One container as `docker inspect` describes it, with the host side of each of its mounts.
package struct NextflowDockerContainer: Sendable, Equatable {
    package let id: String
    /// Docker's state of it, such as `running`, `exited` or `created`.
    package let status: String
    package let mountSources: [String]

    package init(id: String, status: String, mountSources: [String]) {
        self.id = id
        self.status = status
        self.mountSources = mountSources
    }

    /// Whether `docker kill` applies, to a container that runs, is paused or restarts.
    package var isRunning: Bool {
        ["running", "paused", "restarting"].contains(status)
    }
}

extension NextflowDockerContainerCleanup {
    /// The container ids in the lines `docker ps --quiet --no-trunc` prints.
    package static func containerIDs(in listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isContainerID($0) }
    }

    /// Whether `text` is a full container id as `--no-trunc` and `{{.Id}}` print one, 64 lowercase
    /// hexadecimal digits, so no option, name or id prefix ever reaches `docker` as an argument.
    package static func isContainerID(_ text: some StringProtocol) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The containers in the lines ``inspectFormat`` prints. A line that cannot be read is left out, which can only
    /// leave a container running and never stops another one.
    package static func parseInspect(_ output: String) -> [NextflowDockerContainer] {
        struct Mount: Decodable {
            let source: String?

            enum CodingKeys: String, CodingKey {
                case source = "Source"
            }
        }
        var containers: [NextflowDockerContainer] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, isContainerID(fields[0]) else { continue }
            let json = fields[2].trimmingCharacters(in: .whitespaces)
            let mounts: [Mount]
            if json == "null" {
                // Go prints an empty list of mounts as null.
                mounts = []
            } else if let decoded = try? JSONDecoder().decode([Mount].self, from: Data(json.utf8)) {
                mounts = decoded
            } else {
                continue
            }
            containers.append(NextflowDockerContainer(
                id: String(fields[0]),
                status: String(fields[1]),
                mountSources: mounts.compactMap(\.source)
            ))
        }
        return containers
    }

    /// The containers with a mount whose host side is `workDirectory` or lies inside it, compared by whole path
    /// components after resolving links.
    ///
    /// A mount of a folder that holds the work folder does not count, and neither does a sibling whose name starts
    /// with the same letters. A work folder of fewer than three components matches nothing, so a wrong argument
    /// such as `/` or `/tmp` never selects a container.
    package static func containers(
        _ containers: [NextflowDockerContainer],
        mountingInside workDirectory: URL
    ) -> [NextflowDockerContainer] {
        let folder = canonicalHostPath(workDirectory.path)
        guard folder.split(separator: "/").count >= 3 else { return [] }
        return containers.filter { container in
            container.mountSources.contains { source in
                let host = canonicalHostPath(source)
                return host == folder || host.hasPrefix(folder + "/")
            }
        }
    }

    /// A host path in one spelling, whichever way Nextflow, Docker Desktop and Foundation print it.
    ///
    /// Docker Desktop can show a host path under `/host_mnt`, macOS keeps `/var`, `/tmp` and `/etc` as links into
    /// `/private`, and one Nextflow task script holds both spellings of one folder. The part of the path that
    /// exists is read with its links resolved and the rest from its text, so a task folder that is gone still
    /// compares. A relative path stays relative and so matches no work folder.
    package static func canonicalHostPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var components = lexicalComponents(of: path)
        if components.first == "host_mnt" {
            components.removeFirst()
        }
        components = resolvingLinks(components)
        if components.count >= 2, components[0] == "private", ["var", "tmp", "etc"].contains(components[1]) {
            components.removeFirst()
        }
        return "/" + components.joined(separator: "/")
    }

    /// The components of an absolute path with `.` dropped and `..` applied.
    private static func lexicalComponents(of path: String) -> [String] {
        var components: [String] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(String(part))
            }
        }
        return components
    }

    /// The components with the links of their longest existing prefix resolved.
    private static func resolvingLinks(_ components: [String]) -> [String] {
        var existing = components
        var rest: [String] = []
        while !existing.isEmpty {
            if let resolved = realpath("/" + existing.joined(separator: "/"), nil) {
                defer { free(resolved) }
                return lexicalComponents(of: String(cString: resolved)) + rest
            }
            rest.insert(existing.removeLast(), at: 0)
        }
        return components
    }
}
