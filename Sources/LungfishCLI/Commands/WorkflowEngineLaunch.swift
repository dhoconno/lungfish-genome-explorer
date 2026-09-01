// WorkflowEngineLaunch.swift - Resolve how a workflow engine process is launched
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// How `lungfish-cli workflow run` launches a workflow engine (Nextflow or Snakemake).
///
/// The CLI is usually spawned by the app, and an app launched from Finder
/// inherits a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). Looking the engine
/// up with `/usr/bin/env nextflow` therefore fails with exit status 127 even
/// though Lungfish installed its own copy under the managed conda root. The
/// engine is resolved the same way the in-process runners do it: the managed
/// copy wins, and only when it is absent does the launch fall back to a `PATH`
/// lookup. Either way the environment is widened so the engine and the tasks
/// it spawns can find the managed conda tools and Docker Desktop's CLI.
struct WorkflowEngineLaunch: Equatable, Sendable {
    /// The process to execute: the managed engine, or `/usr/bin/env` for a PATH lookup.
    let executableURL: URL
    /// Arguments that precede the engine's own arguments (`["nextflow"]` for a PATH lookup).
    let argumentPrefix: [String]
    /// Environment for the engine process.
    let environment: [String: String]

    /// Whether the launch targets Lungfish's managed copy of the engine.
    var usesManagedExecutable: Bool { argumentPrefix.isEmpty }

    /// Composes the full argument list for the engine process.
    func arguments(_ arguments: [String]) -> [String] {
        argumentPrefix + arguments
    }

    /// Resolves the launch for an engine named after its managed conda environment.
    static func resolve(
        executableName: String,
        homeDirectory: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorkflowEngineLaunch {
        let managedExecutable = CoreToolLocator.executableURL(
            environment: executableName,
            executableName: executableName,
            homeDirectory: homeDirectory
        ).standardizedFileURL
        let hasManagedExecutable = FileManager.default.isExecutableFile(atPath: managedExecutable.path)

        let condaRoot = CoreToolLocator.condaRoot(homeDirectory: homeDirectory).standardizedFileURL
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
            if FileManager.default.isExecutableFile(atPath: bundledJava.path) {
                environment["JAVA_HOME"] = jvmHome.path
            }
        }

        if executableName == "nextflow" {
            environment["NXF_ANSI_LOG"] = "false"
            environment["NXF_HOME"] = LungfishAppIdentity.current
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
}
