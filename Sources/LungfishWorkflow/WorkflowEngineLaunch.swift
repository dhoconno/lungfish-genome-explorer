// WorkflowEngineLaunch.swift - Resolve how a workflow engine process is launched
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// How Lungfish launches a workflow engine (Nextflow or Snakemake).
///
/// This is the one place a Nextflow launch gets its executable and its
/// environment. `lungfish-cli workflow run`, the app's workflow services and
/// the in-process callers (``TaxTriagePipeline``, ``ProcessPBAANextflowRunner``,
/// ``NextflowRunner`` and the version probe in ``BaseWorkflowRunner``) all
/// start from it. A caller that needs a setting of its own states it with
/// ``overridingEnvironment(set:unset:)`` instead of building a second
/// environment.
///
/// The CLI is usually spawned by the app, and an app launched from Finder
/// inherits a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). Looking the engine
/// up with `/usr/bin/env nextflow` therefore fails with exit status 127 even
/// though Lungfish installed its own copy under the managed conda root, so the
/// managed copy wins. ``resolve(executableName:homeDirectory:appIdentity:baseEnvironment:isExecutable:)``
/// still describes a `PATH` lookup when the managed copy is absent, for
/// availability probes and runtime evidence. Every launch goes through
/// ``resolveManaged(executableName:homeDirectory:appIdentity:baseEnvironment:isExecutable:)``,
/// which refuses that fallback. Either way the environment is widened so the
/// engine and the tasks it spawns can find the managed conda tools and Docker
/// Desktop's CLI, and a managed engine gets its bundled JDK as `JAVA_HOME`.
public struct WorkflowEngineLaunch: Equatable, Sendable {
    /// The process to execute: the managed engine, or `/usr/bin/env` for a PATH lookup.
    public let executableURL: URL
    /// Arguments that precede the engine's own arguments (`["nextflow"]` for a PATH lookup).
    public let argumentPrefix: [String]
    /// Environment for the engine process.
    public let environment: [String: String]

    /// Whether the launch targets Lungfish's managed copy of the engine.
    public var usesManagedExecutable: Bool { argumentPrefix.isEmpty }

    /// Composes the full argument list for the engine process.
    public func arguments(_ arguments: [String]) -> [String] {
        argumentPrefix + arguments
    }

    /// Read-only executable availability for configuration preflight.
    public func resolvedExecutableURL(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        if argumentPrefix.isEmpty {
            return isExecutable(executableURL.path) ? executableURL : nil
        }
        guard argumentPrefix.count == 1, let name = argumentPrefix.first,
              !name.contains("/"), !name.isEmpty else { return nil }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            // Relative entries depend on the eventual engine working directory.
            // Availability must not attest to an executable resolved in this caller's directory.
            guard directory.hasPrefix("/") else { return nil }
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if isExecutable(candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    /// This launch with caller-stated changes to its environment.
    ///
    /// Names in `unset` are removed first, then `set` adds or replaces
    /// variables, so a name in both ends up set. The executable and arguments
    /// are unchanged. TaxTriage states its profile settings this way, on top of
    /// the shared environment rather than in a copy of it.
    public func overridingEnvironment(
        set values: [String: String] = [:],
        unset names: Set<String> = []
    ) -> WorkflowEngineLaunch {
        var environment = self.environment
        for name in names {
            environment.removeValue(forKey: name)
        }
        for (name, value) in values {
            environment[name] = value
        }
        return WorkflowEngineLaunch(
            executableURL: executableURL,
            argumentPrefix: argumentPrefix,
            environment: environment
        )
    }

    /// Resolves the launch for an engine named after its managed conda environment.
    ///
    /// - Parameter isExecutable: The file probe that decides whether the
    ///   managed engine and its bundled JDK exist. Tests pass their own to
    ///   describe a Mac with or without a JDK, whatever this machine has.
    public static func resolve(
        executableName: String,
        homeDirectory: URL,
        appIdentity: LungfishAppIdentity = .current,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> WorkflowEngineLaunch {
        let managedExecutable = CoreToolLocator.executableURL(
            environment: executableName,
            executableName: executableName,
            homeDirectory: homeDirectory,
            appIdentity: appIdentity
        ).standardizedFileURL
        let hasManagedExecutable = isExecutable(managedExecutable.path)

        let condaRoot = CoreToolLocator.condaRoot(homeDirectory: homeDirectory, appIdentity: appIdentity).standardizedFileURL
        var toolPaths: [String] = []
        if hasManagedExecutable {
            toolPaths.append(managedExecutable.deletingLastPathComponent().path)
        }
        toolPaths.append(condaRoot.appendingPathComponent("bin", isDirectory: true).path)
        // Docker Desktop symlinks its CLI here; Nextflow tasks resolve `docker` through PATH.
        toolPaths.append("/usr/local/bin")

        var environment = baseEnvironment
        let existingPaths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        var mergedPaths: [String] = []
        for path in toolPaths + existingPaths where !path.isEmpty && !mergedPaths.contains(path) {
            mergedPaths.append(path)
        }
        environment["PATH"] = mergedPaths.joined(separator: ":")
        environment["HOME"] = homeDirectory.path
        environment["MAMBA_ROOT_PREFIX"] = condaRoot.path

        // Conda's activation script exports JAVA_HOME=$CONDA_PREFIX/lib/jvm. A
        // direct launch never runs it, and without a system JDK the Nextflow
        // launcher then has no Java at all.
        if hasManagedExecutable {
            let jvmHome = managedExecutable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("lib/jvm", isDirectory: true)
            let bundledJava = jvmHome.appendingPathComponent("bin/java")
            if isExecutable(bundledJava.path) {
                environment["JAVA_HOME"] = jvmHome.path
            }
        }

        if executableName == "nextflow" {
            environment["NXF_ANSI_LOG"] = "false"
            environment["NXF_HOME"] = appIdentity
                .nextflowHomeURL(homeDirectory: homeDirectory)
                .path
        }

        if hasManagedExecutable {
            return WorkflowEngineLaunch(
                executableURL: managedExecutable,
                argumentPrefix: [],
                environment: environment
            )
        }
        return WorkflowEngineLaunch(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            argumentPrefix: [executableName],
            environment: environment
        )
    }

    /// The launch every engine start uses: Lungfish's managed copy of the
    /// engine, never a copy found on `PATH`.
    ///
    /// A `PATH` fallback (`~/miniforge3/bin/nextflow`, say) is a different,
    /// unpinned version; nf-core/viralrecon then failed deep inside Nextflow
    /// ("nf-schema requires Nextflow >=25.04.0") with no hint that the
    /// managed engine was simply missing from this tool root (the Debug
    /// channel's `~/.lungfish-debug`, for instance). The missing engine is a
    /// ``MissingToolError``, so the CLI exits with the documented status 126
    /// and names Required Setup. In-process callers report it as their own
    /// "not installed" error. ``resolve(executableName:homeDirectory:appIdentity:baseEnvironment:isExecutable:)``
    /// keeps the fallback for availability probes and runtime evidence only.
    public static func resolveManaged(
        executableName: String,
        homeDirectory: URL,
        appIdentity: LungfishAppIdentity = .current,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) throws -> WorkflowEngineLaunch {
        let launch = resolve(
            executableName: executableName,
            homeDirectory: homeDirectory,
            appIdentity: appIdentity,
            baseEnvironment: baseEnvironment,
            isExecutable: isExecutable
        )
        guard launch.usesManagedExecutable else {
            throw WorkflowEngineNotInstalled(
                executableName: executableName,
                expectedPath: CoreToolLocator.executableURL(
                    environment: executableName,
                    executableName: executableName,
                    homeDirectory: homeDirectory,
                    appIdentity: appIdentity
                ).standardizedFileURL.path
            )
        }
        return launch
    }
}

/// The managed workflow engine is not installed in this tool root.
///
/// Conforms to ``MissingToolError`` so `lungfish-cli` exits 126 with this
/// message, whether or not a different copy of the engine is on `PATH`.
public struct WorkflowEngineNotInstalled: Error, LocalizedError, MissingToolError, Equatable, Sendable {
    public let executableName: String
    /// Where the managed copy was expected.
    public let expectedPath: String

    public init(executableName: String, expectedPath: String) {
        self.executableName = executableName
        self.expectedPath = expectedPath
    }

    public var missingToolName: String? { executableName }

    public var displayName: String {
        switch executableName {
        case "nextflow": return "Nextflow"
        case "snakemake": return "Snakemake"
        default: return executableName
        }
    }

    public var errorDescription: String? {
        "\(displayName) is not installed in Lungfish's managed tool root (expected \(expectedPath)). "
            + "\(displayName) is part of LGE's Required Setup: in the app, open the Welcome window and click Install, "
            + "or run `\(CLICommandIdentity.executableName) tools update --apply --yes --required-only`. "
            + "A \(executableName) found elsewhere on PATH is not used."
    }
}
