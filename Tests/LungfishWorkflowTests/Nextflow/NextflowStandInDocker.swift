// NextflowStandInDocker.swift - A stand-in docker CLI that records each call, for the container cleanup tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S10, decision N5. The container cleanup tests run against a `/bin/sh` script in place of
// `docker`, so they need no Docker. The script records the arguments of each call, answers `ps` and `inspect`
// from files the test writes, and at `ps`, `kill` and `rm` records whether the engine's tree still runs, whether
// the run's record exists and whether its scratch does. A test can make `ps` hang, as a daemon that never
// answers would, or fail, as a stopped daemon does.

import Foundation
import LungfishCore
@testable import LungfishWorkflow

/// A stand-in `docker` in a folder of its own, with the files that drive and record it.
struct NextflowStandInDocker {
    /// One container the stand-in daemon knows, as `docker inspect` describes it.
    struct Container {
        let id: String
        let status: String
        let mountSources: [String]
    }

    /// One call, with the argument count the script saw beside the arguments it recorded, so a test can tell
    /// that each id arrived as an argument of its own.
    struct Call: Equatable {
        let argumentCount: Int
        let arguments: [String]
    }

    let folder: URL

    var executable: URL { folder.appendingPathComponent("docker") }

    /// Writes the script into a new folder under `parent`.
    static func make(in parent: URL) throws -> NextflowStandInDocker {
        let folder = parent.appendingPathComponent("docker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let docker = NextflowStandInDocker(folder: folder)
        try script(control: folder.path).write(to: docker.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.executable.path)
        return docker
    }

    /// Makes the daemon know `containers`, which `ps` lists and `inspect` describes, in this order.
    func serve(_ containers: [Container]) throws {
        let listing = containers.map { $0.id + "\n" }.joined()
        try listing.write(to: file("ps.out"), atomically: true, encoding: .utf8)
        var lines = ""
        for container in containers {
            let mounts = container.mountSources.map { source -> [String: Any] in
                ["Type": "bind", "Source": source, "Destination": source, "Mode": "", "RW": true, "Propagation": "rprivate"]
            }
            let json = try JSONSerialization.data(withJSONObject: mounts, options: [.sortedKeys, .withoutEscapingSlashes])
            lines += "\(container.id)|\(container.status)|\(String(decoding: json, as: UTF8.self))\n"
        }
        try lines.write(to: file("inspect.out"), atomically: true, encoding: .utf8)
    }

    /// Makes every later observation record whether one of `pids` still runs, whether `record` exists and
    /// whether `scratch` exists.
    func watch(pids: [Int32], record: URL, scratch: URL) throws {
        let context = """
        WATCHED='\(pids.map(String.init).joined(separator: " "))'
        RECORD='\(record.path)'
        SCRATCH='\(scratch.path)'

        """
        try context.write(to: file("context"), atomically: true, encoding: .utf8)
    }

    /// Makes `ps` wait 60 s before it answers, as a daemon that never answers would.
    func hangOnListing() {
        FileManager.default.createFile(atPath: file("hang").path, contents: nil)
    }

    /// Makes `ps` fail as it does when the daemon is not running.
    func failListing() {
        FileManager.default.createFile(atPath: file("ps-fails").path, contents: nil)
    }

    /// Every call so far, in call order.
    func calls() -> [Call] {
        lines(of: "calls").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return Call(argumentCount: Int(fields[0]) ?? -1, arguments: Array(fields.dropFirst()))
        }
    }

    /// The arguments of every call so far, in call order.
    func arguments() -> [[String]] {
        calls().map(\.arguments)
    }

    /// What `ps`, `kill` and `rm` saw, one line each, such as `kill tree=gone record=absent scratch=present`.
    func observations() -> [String] {
        lines(of: "observations")
    }

    /// The pid of the `ps` call that hangs, once it has started.
    func hungPID() -> Int32? {
        lines(of: "hung.pid").first.flatMap { Int32($0) }
    }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    private func lines(of name: String) -> [String] {
        ((try? String(contentsOf: file(name), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    private static func script(control: String) -> String {
        """
        #!/bin/sh
        control='\(control)'
        line="$#"
        for argument in "$@"; do
          line="$line\t$argument"
        done
        echo "$line" >> "$control/calls"
        observe() {
          tree=gone
          record=absent
          scratch=absent
          if [ -f "$control/context" ]; then
            . "$control/context"
            for pid in $WATCHED; do
              state=$(ps -o stat= -p "$pid" 2>/dev/null)
              case "$state" in
                ''|Z*) ;;
                *) tree=running ;;
              esac
            done
            [ -e "$RECORD" ] && record=present
            [ -d "$SCRATCH" ] && scratch=present
          fi
          echo "$1 tree=$tree record=$record scratch=$scratch" >> "$control/observations"
        }
        case "$1" in
          ps)
            observe ps
            if [ -e "$control/hang" ]; then
              echo $$ > "$control/hung.pid"
              sleep 60
            fi
            if [ -e "$control/ps-fails" ]; then
              echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
              exit 1
            fi
            cat "$control/ps.out" 2>/dev/null
            ;;
          inspect)
            cat "$control/inspect.out" 2>/dev/null
            ;;
          kill|rm)
            observe "$1"
            shift
            for id in "$@"; do
              echo "$id"
            done
            ;;
          *)
            echo "stand-in docker: unknown command $1" >&2
            exit 1
            ;;
        esac

        """
    }
}

/// A Docker probe whose daemon answers and whose CLI is the stand-in, or none.
struct StandInDockerProbe: ContainerRuntimeProbing {
    let dockerPath: String?

    func dockerCLIPath() -> String? { dockerPath }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil)
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }
}
