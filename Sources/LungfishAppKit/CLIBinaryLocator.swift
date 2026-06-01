// CLIBinaryLocator.swift — Pure Foundation resolver for the `lungfish-cli` binary.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "CLIBinaryLocator")

/// Locates the `lungfish-cli` binary across the supported launch layouts.
///
/// This is a dependency-free utility (Bundle/FileManager/ProcessInfo/Process/URL only)
/// so it can live in the shared ``LungfishAppKit`` kernel and be reused by both
/// app-internal runners and leaf modules without dragging in OperationCenter or
/// event-streaming machinery.
public enum CLIBinaryLocator {

    /// Resolves the `lungfish-cli` binary path.
    ///
    /// Search order:
    /// 1. `<AppBundle>/Contents/MacOS/lungfish-cli` (release)
    /// 2. `.build/arm64-apple-macosx/debug/lungfish-cli` (development)
    /// 3. PATH lookup via `/usr/bin/which`
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
            }
        )
    }

    public static func resolveCLIPath(
        mainExecutableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        environment: [String: String] = [:],
        pathLookup: () -> URL?
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
            let bundledCLI = executableDirectory.appendingPathComponent("lungfish-cli")
            if FileManager.default.isExecutableFile(atPath: bundledCLI.path) {
                return bundledCLI
            }
        }

        let developmentCandidates = [
            ".build/arm64-apple-macosx/debug/lungfish-cli",
            ".build/debug/lungfish-cli",
        ]

        for projectRoot in developmentProjectRoots(
            mainExecutableURL: mainExecutableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL
        ) {
            for relativePath in developmentCandidates {
                let candidate = projectRoot.appendingPathComponent(relativePath)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
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

    private static func pathLookupForCLI() -> URL? {
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["lungfish-cli"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            logger.warning("PATH lookup for lungfish-cli failed: \(error.localizedDescription, privacy: .public)")
        }

        return nil
    }
}
