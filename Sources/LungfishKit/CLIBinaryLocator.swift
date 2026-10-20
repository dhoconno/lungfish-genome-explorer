// CLIBinaryLocator.swift — Pure Foundation resolver for the `lungfish-cli` binary.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "CLIBinaryLocator")

/// Locates the `lungfish-cli` binary across the supported launch layouts.
///
/// This is a dependency-free utility (Bundle/FileManager/ProcessInfo/ToolProcess/URL only)
/// so it can live in the shared ``LungfishKit`` kernel and be reused by both
/// app-internal runners and leaf modules without dragging in OperationCenter or
/// event-streaming machinery.
public enum CLIBinaryLocator {

    /// Resolves the `lungfish-cli` binary path.
    ///
    /// Search order:
    /// 1. `<AppBundle>/Contents/MacOS/lungfish-cli` (release)
    /// 2. SwiftPM's active package binary directory (development), asked with a probe that
    ///    gives up after `swiftPMProbeTimeout`. The probe blocks its thread, so never call
    ///    this on the main thread.
    /// 3. A search of the directories in the `PATH` variable, with no process
    ///    (``ExecutablePathSearch``)
    public static func cliBinaryPath() -> URL? {
        resolveCLIPath(
            mainExecutableURL: Bundle.main.executableURL,
            currentWorkingDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            environment: ProcessInfo.processInfo.environment,
            pathLookup: {
                pathLookupForCLI()
            },
            swiftPMBinPathLookup: { packageRoot in
                swiftPMDevelopmentBinPath(packageRoot: packageRoot)
            }
        )
    }

    public static func resolveCLIPath(
        mainExecutableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        environment: [String: String] = [:],
        pathLookup: () -> URL?
    ) -> URL? {
        resolveCLIPath(
            mainExecutableURL: mainExecutableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL,
            environment: environment,
            pathLookup: pathLookup,
            swiftPMBinPathLookup: { packageRoot in
                swiftPMDevelopmentBinPath(packageRoot: packageRoot)
            }
        )
    }

    public static func resolveCLIPath(
        mainExecutableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        environment: [String: String] = [:],
        pathLookup: () -> URL?,
        swiftPMBinPathLookup: (URL) -> URL?
    ) -> URL? {
        if let explicitPath = environment["LUNGFISH_CLI_PATH"],
           !explicitPath.isEmpty {
            let explicitCLI = URL(fileURLWithPath: explicitPath)
            if FileManager.default.isExecutableFile(atPath: explicitCLI.path) {
                return explicitCLI
            }
        }

        if let mainExecutableURL {
            let executableDirectory = mainExecutableURL.deletingLastPathComponent()
            let bundledCLI = executableDirectory.appendingPathComponent(CLICommandIdentity.executableName)
            if FileManager.default.isExecutableFile(atPath: bundledCLI.path) {
                return bundledCLI
            }
        }

        for projectRoot in developmentProjectRoots(
            mainExecutableURL: mainExecutableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL
        ) {
            guard let binPath = swiftPMBinPathLookup(projectRoot) else {
                continue
            }
            let candidate = binPath.appendingPathComponent(CLICommandIdentity.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let pathCLI = pathLookup(), FileManager.default.isExecutableFile(atPath: pathCLI.path) {
            return pathCLI
        }

        return nil
    }

    private static func developmentProjectRoots(
        mainExecutableURL: URL?,
        currentWorkingDirectoryURL: URL?
    ) -> [URL] {
        let fileManager = FileManager.default
        let anchors = [
            currentWorkingDirectoryURL,
            mainExecutableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL }

        var roots: [URL] = []
        var seen = Set<String>()

        func appendPackageRoot(from start: URL) {
            var current = start
            for _ in 0..<12 {
                let packageSwift = current.appendingPathComponent("Package.swift")
                if fileManager.fileExists(atPath: packageSwift.path) {
                    if seen.insert(current.path).inserted {
                        roots.append(current)
                    }
                    return
                }

                let parent = current.deletingLastPathComponent()
                if parent.path == current.path {
                    return
                }
                current = parent
            }
        }

        for anchor in anchors {
            appendPackageRoot(from: anchor)
        }
        return roots
    }

    /// The longest the SwiftPM bin path probe may run. `swift build --show-bin-path` waits on the build
    /// lock another `swift build` or `swift test` holds, and the 2.12 verify run waited 884 s on it
    /// (R6 of M879). A probe that outlasts this returns nil, so the search goes on to the next step.
    static let swiftPMProbeTimeout: Duration = .seconds(120)

    private static func swiftPMDevelopmentBinPath(packageRoot: URL) -> URL? {
        swiftPMDevelopmentBinPath(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift",
                "build",
                "--package-path", packageRoot.path,
                "--show-bin-path",
            ],
            timeout: swiftPMProbeTimeout
        )
    }

    /// The probe behind ``swiftPMDevelopmentBinPath(packageRoot:)``, with the program, its arguments and
    /// the bound as parameters so a test can run a stand-in. It returns the last line of the program's
    /// standard output as a directory, and nil when the program fails, cannot start or outlasts `timeout`.
    static func swiftPMDevelopmentBinPath(executable: URL, arguments: [String], timeout: Duration) -> URL? {
        let spec = ToolProcessSpec(
            executableURL: executable,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: .capture(),
            stderr: .discard,
            timeout: timeout,
            label: "swift build --show-bin-path"
        )

        do {
            let result = try ToolProcess.runBlocking(spec)
            guard result.isSuccess else {
                return nil
            }

            guard let path = result.stdoutText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            logger.warning("SwiftPM bin path lookup for \(CLICommandIdentity.executableName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func pathLookupForCLI() -> URL? {
        pathLookupForCLI(path: ProcessInfo.processInfo.environment["PATH"])
    }

    /// Searches the directories of `path` for the CLI, with no process.
    static func pathLookupForCLI(path: String?) -> URL? {
        ExecutablePathSearch.find(CLICommandIdentity.executableName, inPath: path)
    }
}
