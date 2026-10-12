// LiveNextflowDocker.swift - The Docker side of a live Nextflow class
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner direction O5 (Phase 2.9). A live class runs the real Nextflow, whose tasks run in Docker
// containers. This file holds the three things such a class needs from Docker.
//
//   1. A probe, `docker info` with a 30 s bound. It never starts Docker Desktop. A Docker that gives
//      no answer is reported to ToolAvailability.skipOrFail, so the test skips on a Mac without a
//      running Docker and fails under LUNGFISH_REQUIRE_TOOLS=1.
//   2. The containers whose mounts hold a run's own work folder. Every task container of a real
//      Nextflow run mounts its task folder, which lies inside the work folder, and also mounts the
//      system temporary folder, which holds every run's work folder. So a container belongs to a run
//      when a mount's host side is the work folder or lies inside it, and never when a mount's host
//      side only contains it.
//   3. Removal of exactly those containers.
//
// The runner is a closure, so a unit test describes a daemon with containers of other runs and
// checks that a teardown touches none of them, with no Docker on the Mac.

import Foundation
import LungfishWorkflow

/// A Docker client for a live class, with the daemon behind a closure.
public struct LiveNextflowDocker: Sendable {
    /// `docker info` gets this long to answer.
    public static let probeTimeout: TimeInterval = 30
    /// The probe asks for `docker info` and nothing else. Nothing a live class runs starts Docker Desktop.
    public static let probeArguments = ["info"]
    /// The bound of `ps`, `inspect` and `rm`.
    public static let commandTimeout: TimeInterval = 60

    private static let inspectBatchSize = 50
    private static let inspectFormat = "{{.Id}}|{{json .Mounts}}"

    /// What a `docker` command printed.
    public struct Output: Equatable, Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public init(status: Int32, stdout: String = "", stderr: String = "") {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// A command that gave no answer within its bound.
    public struct TimedOut: Error, Equatable, Sendable {
        public let seconds: TimeInterval

        public init(seconds: TimeInterval) {
            self.seconds = seconds
        }
    }

    /// A command that ran and failed, or printed what could not be read.
    public struct CommandFailed: Error, Equatable, CustomStringConvertible, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Runs `docker <arguments>` and throws `TimedOut` when it does not end within `timeout` seconds.
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) throws -> Output

    /// How `docker info` ended.
    public enum ProbeOutcome: Equatable, Sendable {
        case answers
        case noAnswer(seconds: TimeInterval)
        case fails(status: Int32, detail: String)
        case cannotRun(String)

        /// Why a live class cannot run, or nil when Docker answered. This is the text for `ToolAvailability.skipOrFail`.
        public var problem: String? {
            switch self {
            case .answers:
                return nil
            case .noAnswer(let seconds):
                return "docker info gave no answer within \(String(format: "%g", seconds)) s. "
                    + "A live class never starts Docker Desktop, so start it first."
            case .fails(let status, let detail):
                return "docker info exited \(status): \(detail). "
                    + "The Docker daemon is not running, and a live class never starts Docker Desktop."
            case .cannotRun(let message):
                return "docker could not be run: \(message)"
            }
        }
    }

    /// A container and the host side of each of its mounts, as `docker inspect` prints them.
    public struct Container: Equatable, Sendable {
        public let id: String
        public let mountSources: [String]

        public init(id: String, mountSources: [String]) {
            self.id = id
            self.mountSources = mountSources
        }
    }

    public let executable: URL
    private let runner: Runner

    public init(executable: URL, runner: @escaping Runner) {
        self.executable = executable
        self.runner = runner
    }

    /// The installed `docker` CLI, found the way the app finds it, or nil.
    public static func locateExecutable() -> URL? {
        SystemContainerRuntimeProbe().dockerCLIPath().map { URL(fileURLWithPath: $0) }
    }

    /// A client that runs `executable` for real, through `ProcessRunner`.
    public static func system(executable: URL) -> LiveNextflowDocker {
        LiveNextflowDocker(executable: executable) { arguments, timeout in
            do {
                let result = try ProcessRunner.run(executable, arguments, timeout: timeout)
                return Output(status: result.status, stdout: result.stdout, stderr: result.stderr)
            } catch ToolAvailabilityError.required(let message) where message.hasPrefix("timeout running") {
                throw TimedOut(seconds: timeout)
            }
        }
    }

    /// Runs one `docker` command.
    public func run(_ arguments: [String], timeout: TimeInterval = LiveNextflowDocker.commandTimeout) throws -> Output {
        try runner(arguments, timeout)
    }

    // MARK: - The probe

    /// Asks `docker info`, which answers from the daemon that is running and starts nothing.
    public func probe(timeout: TimeInterval = LiveNextflowDocker.probeTimeout) -> ProbeOutcome {
        do {
            let output = try runner(Self.probeArguments, timeout)
            if output.status == 0 {
                return .answers
            }
            let detail = Self.firstLine(of: output.stderr) ?? Self.firstLine(of: output.stdout) ?? "no output"
            return .fails(status: output.status, detail: detail)
        } catch let timedOut as TimedOut {
            return .noAnswer(seconds: timedOut.seconds)
        } catch {
            return .cannotRun(String(describing: error))
        }
    }

    // MARK: - The containers of one run

    /// Every container the daemon knows, with the host side of its mounts.
    public func containers(includingStopped: Bool = true) throws -> [Container] {
        let listing = try run(includingStopped ? ["ps", "-a", "-q", "--no-trunc"] : ["ps", "-q", "--no-trunc"])
        guard listing.status == 0 else {
            throw CommandFailed("docker ps exited \(listing.status): \(Self.firstLine(of: listing.stderr) ?? "no output")")
        }
        let ids = listing.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var found: [Container] = []
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start ..< min(start + Self.inspectBatchSize, ids.count)])
            start += Self.inspectBatchSize
            let inspected = try run(["inspect", "--type", "container", "--format", Self.inspectFormat] + batch)
            // A container that ended between `ps` and `inspect` is missing from stdout and the command
            // exits 1. That is no failure. Anything else without output is.
            if inspected.status != 0, inspected.stdout.isEmpty,
               inspected.stderr.range(of: "No such") == nil {
                throw CommandFailed(
                    "docker inspect exited \(inspected.status): \(Self.firstLine(of: inspected.stderr) ?? "no output")"
                )
            }
            found += try Self.parseInspect(inspected.stdout)
        }
        return found
    }

    /// The containers whose mounts hold `workFolder`, running or stopped.
    public func containers(holding workFolder: URL, includingStopped: Bool = true) throws -> [Container] {
        let everything = try containers(includingStopped: includingStopped)
        return Self.filter(everything, holding: workFolder)
    }

    /// Removes `containers` with `docker rm -f -v`, which also removes their anonymous volumes.
    public func remove(_ containers: [Container]) throws {
        guard !containers.isEmpty else { return }
        let removal = try run(["rm", "-f", "-v"] + containers.map(\.id))
        guard removal.status == 0 else {
            throw CommandFailed("docker rm exited \(removal.status): \(Self.firstLine(of: removal.stderr) ?? "no output")")
        }
    }

    // MARK: - Reading and matching (pure)

    /// Reads the lines `docker inspect --format '{{.Id}}|{{json .Mounts}}'` prints.
    public static func parseInspect(_ output: String) throws -> [Container] {
        struct Mount: Decodable {
            let source: String?

            enum CodingKeys: String, CodingKey {
                case source = "Source"
            }
        }
        var containers: [Container] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let bar = line.firstIndex(of: "|") else {
                throw CommandFailed("unreadable docker inspect line: \(line.prefix(80))")
            }
            let id = String(line[..<bar])
            let json = Data(line[line.index(after: bar)...].utf8)
            do {
                let mounts = try JSONDecoder().decode([Mount]?.self, from: json) ?? []
                containers.append(Container(id: id, mountSources: mounts.compactMap(\.source)))
            } catch {
                throw CommandFailed("unreadable mounts of container \(id.prefix(12)): \(error)")
            }
        }
        return containers
    }

    /// A host path in one spelling, whichever way Nextflow, Docker Desktop and Foundation print it.
    ///
    /// macOS keeps `/var`, `/tmp` and `/etc` as links into `/private`, and one Nextflow task script
    /// holds both `/private/var/folders/...` and `/var/folders/...` for the same folder. Docker Desktop
    /// shows some host paths under `/host_mnt`. This reads the string only, so it works for a task
    /// folder that is gone.
    public static func canonicalHostPath(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(part)
        }
        if components.first == "host_mnt" {
            components.removeFirst()
        }
        if components.first == "private", let second = components.dropFirst().first,
           ["var", "tmp", "etc"].contains(second) {
            components.removeFirst()
        }
        return "/" + components.joined(separator: "/")
    }

    /// The containers with a mount whose host side is `workFolder` or lies inside it.
    ///
    /// A mount of a folder that contains `workFolder` (the system temporary folder every Nextflow
    /// task mounts) does not count. Neither does a sibling whose name only starts with the same
    /// letters. A work folder with fewer than three path components matches nothing, so a wrong
    /// argument such as `/` or `/tmp` can never select a foreign container.
    public static func filter(_ containers: [Container], holding workFolder: URL) -> [Container] {
        let folder = canonicalHostPath(workFolder.path)
        guard folder.split(separator: "/").count >= 3 else { return [] }
        return containers.filter { container in
            container.mountSources.contains { source in
                let host = canonicalHostPath(source)
                return host == folder || host.hasPrefix(folder + "/")
            }
        }
    }

    /// The containers with a mount whose host side is one of `workFolders` or lies inside one.
    public static func filter(_ containers: [Container], holdingAny workFolders: [URL]) -> [Container] {
        containers.filter { container in workFolders.contains { !Self.filter([container], holding: $0).isEmpty } }
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
