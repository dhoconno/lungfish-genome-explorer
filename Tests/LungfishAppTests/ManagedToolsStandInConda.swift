// ManagedToolsStandInConda.swift - A conda root whose micromamba finishes, for the managed tools parity class
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// A conda root under a side's storage root whose `micromamba` completes (Phase 2.10 lane A52 M3b,
/// QA 4). The stand-in answers three calls and nothing else. `--version` gives the lock's bootstrap
/// version, `create -n NAME ...` copies the template environment `templates/NAME`, and `run -n ENV TOOL
/// ARGS` runs `envs/ENV/bin/TOOL`. Its folder is found from its own path, so the three sides of a case
/// each use their own root. The in-process route and the built CLI both drive it through
/// `CondaManager`, so the roots they leave are what the two routes write.
///
/// An environment the case leaves current holds the `conda-meta` record of the lock's pin, which is
/// what `DependencyPlanner` reads, and an executable for each name the lock gives it. An outdated
/// environment holds an older version of the same package. A template holds the pin and executables
/// that print the words the environment's smoke test requires, so a created environment verifies.
enum ManagedToolsStandInConda {
    /// The folders of one environment's pin in the lock.
    struct Pin {
        let environment: String
        let spec: CondaSpec
        let executables: [String]
    }

    /// The pin of `environment`, from the tools or the pack tools of the bundled lock.
    static func pin(of environment: String) -> Pin? {
        let lock = ManagedToolLock.bundled
        let entry: (spec: String, executables: [String])? =
            lock.tools.first { $0.environment == environment }.map { ($0.packageSpec, $0.executables) }
            ?? lock.packTools.first { $0.environment == environment }.map { ($0.packageSpec, $0.executables) }
        guard let entry, let spec = CondaSpec(spec: entry.spec) else { return nil }
        return Pin(environment: environment, spec: spec, executables: entry.executables)
    }

    /// The words the smoke test of `environment` requires in its output, else the environment's name.
    static func smokeWords(of environment: String) -> String {
        let requirement = PluginPack.builtIn.lazy
            .flatMap(\.toolRequirements)
            .first { $0.environment == environment }
        return requirement?.smokeTest?.requiredOutputSubstring ?? environment
    }

    /// The version `micromamba --version` prints, as the lock's bootstrap pin reads without its build.
    static var bootstrapVersion: String {
        let pinned = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.9.0-0"
        return pinned.split(separator: "-").first.map(String.init) ?? pinned
    }

    static func micromambaScript() -> String {
        #"""
        #!/bin/sh
        root="$(cd "$(dirname "$0")/.." && pwd)"
        case "$1" in
          --version)
            echo "\#(bootstrapVersion)"
            exit 0
            ;;
          create)
            name=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "-n" ]; then name="$argument"; fi
              previous="$argument"
            done
            if [ -z "$name" ] || [ ! -d "$root/templates/$name" ]; then
              echo "stand-in micromamba: no template for '$name'" >&2
              exit 1
            fi
            rm -rf "$root/envs/$name"
            mkdir -p "$root/envs"
            cp -R "$root/templates/$name" "$root/envs/$name"
            exit 0
            ;;
          run)
            shift 2
            environment="$1"
            tool="$2"
            shift 2
            exec "$root/envs/$environment/bin/$tool" "$@"
            ;;
        esac
        echo "stand-in micromamba: unsupported call: $*" >&2
        exit 2
        """#
    }

    /// Writes the environment `pin` at `directory`. `version` replaces the pinned version, for an
    /// outdated environment. Each executable prints `words`.
    static func writeEnvironment(_ pin: Pin, at directory: URL, version: String? = nil, words: String) throws {
        let fileManager = FileManager.default
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let meta = directory.appendingPathComponent("conda-meta", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
        let quoted = words.replacingOccurrences(of: "'", with: "'\\''")
        for name in Set(pin.executables) {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\necho '\(quoted) (stand-in)'\n".write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let packageVersion = version ?? pin.spec.version
        let build = version == nil ? (pin.spec.build ?? "h0000000_0") : "h0000000_0"
        let record: [String: String] = [
            "name": pin.spec.name, "version": packageVersion, "build": build,
            "subdir": "osx-arm64", "channel": pin.spec.channel ?? "conda-forge",
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try data.write(to: meta.appendingPathComponent("\(pin.spec.name)-\(packageVersion)-\(build).json"))
    }

    /// Builds the conda root of a side under `storageRoot`: the stand-in micromamba, the
    /// environments `current` and `outdated`, and a template for each of `templates`.
    static func make(
        storageRoot: URL,
        current: [String],
        outdated: [String],
        templates: [String]
    ) throws {
        let fileManager = FileManager.default
        let conda = storageRoot.appendingPathComponent("conda", isDirectory: true)
        try fileManager.createDirectory(at: conda.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        let micromamba = conda.appendingPathComponent("bin/micromamba")
        try micromambaScript().write(to: micromamba, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        for (names, folder, older) in [(current, "envs", false), (outdated, "envs", true), (templates, "templates", false)] {
            for name in names {
                guard let pin = pin(of: name) else { throw StandInError.unpinned(name) }
                try writeEnvironment(
                    pin,
                    at: conda.appendingPathComponent("\(folder)/\(name)", isDirectory: true),
                    version: older ? "0.0.1" : nil,
                    words: smokeWords(of: name)
                )
            }
        }
    }

    enum StandInError: Error, CustomStringConvertible {
        case unpinned(String)
        var description: String {
            switch self {
            case .unpinned(let name): return "The bundled lock pins no environment named \(name)"
            }
        }
    }
}
