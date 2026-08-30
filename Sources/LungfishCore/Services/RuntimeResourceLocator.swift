// RuntimeResourceLocator.swift - Portable runtime resource discovery
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum RuntimeResourceTarget: String, Sendable {
    case app
    case workflow

    fileprivate var bundleNameHints: [String] {
        switch self {
        case .app:
            return [
                "LungfishGenomeBrowser_LungfishApp.bundle",
                "LungfishApp_LungfishApp.bundle",
                "LungfishApp.bundle",
            ]
        case .workflow:
            return [
                "LungfishGenomeBrowser_LungfishWorkflow.bundle",
                "LungfishWorkflow_LungfishWorkflow.bundle",
                "LungfishWorkflow.bundle",
            ]
        }
    }

    fileprivate var bundleNameFragment: String {
        switch self {
        case .app:
            return "LungfishApp"
        case .workflow:
            return "LungfishWorkflow"
        }
    }

    fileprivate var sourceResourceComponents: [String] {
        switch self {
        case .app:
            return ["Sources", "LungfishApp", "Resources"]
        case .workflow:
            return ["Sources", "LungfishWorkflow", "Resources"]
        }
    }
}

/// Resolves packaged resources relative to the installed app bundle or CLI layout.
///
/// This deliberately avoids SwiftPM's generated `Bundle.module` accessor in
/// production runtime code so release binaries do not depend on build-machine
/// bundle paths.
public enum RuntimeResourceLocator {

    public static func path(_ relativePath: String, in target: RuntimeResourceTarget) -> URL? {
        path(
            relativePath,
            in: target,
            mainResourceURL: Bundle.main.resourceURL,
            executableURL: defaultExecutableURL(),
            currentWorkingDirectoryURL: defaultCurrentWorkingDirectoryURL(fileManager: .default),
            fileManager: .default
        )
    }

    public static func resourceRoots(for target: RuntimeResourceTarget) -> [URL] {
        resourceRoots(
            for: target,
            mainResourceURL: Bundle.main.resourceURL,
            executableURL: defaultExecutableURL(),
            currentWorkingDirectoryURL: defaultCurrentWorkingDirectoryURL(fileManager: .default),
            fileManager: .default
        )
    }

    static func path(
        _ relativePath: String,
        in target: RuntimeResourceTarget,
        mainResourceURL: URL?,
        executableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        fileManager: FileManager
    ) -> URL? {
        for resourceRoot in resourceRoots(
            for: target,
            mainResourceURL: mainResourceURL,
            executableURL: executableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL,
            fileManager: fileManager
        ) {
            let candidate = resourceRoot.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func resourceRoots(
        for target: RuntimeResourceTarget,
        mainResourceURL: URL?,
        executableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        fileManager: FileManager
    ) -> [URL] {
        var roots: [URL] = []
        var seenPaths = Set<String>()
        let allowSourceFallback = shouldAllowSourceFallback(
            mainResourceURL: mainResourceURL,
            executableURL: executableURL
        )

        func appendIfExists(_ url: URL?) {
            guard let url else { return }
            let normalized = url.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: normalized.path) else { return }
            if seenPaths.insert(normalized.path).inserted {
                roots.append(normalized)
            }
        }

        func appendBundleRoots(in directory: URL?) {
            guard let directory else { return }

            for bundleName in target.bundleNameHints {
                let bundleURL = directory.appendingPathComponent(bundleName)
                appendIfExists(bundleURL.appendingPathComponent("Contents/Resources"))
                appendIfExists(bundleURL)
            }

            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                return
            }

            for item in contents where item.hasSuffix(".bundle") && item.contains(target.bundleNameFragment) {
                let bundleURL = directory.appendingPathComponent(item)
                appendIfExists(bundleURL.appendingPathComponent("Contents/Resources"))
                appendIfExists(bundleURL)
            }
        }

        func appendSourceResources(from start: URL?) {
            guard var current = start?.resolvingSymlinksInPath().standardizedFileURL else { return }

            for _ in 0..<12 {
                let packageSwift = current.appendingPathComponent("Package.swift")
                if fileManager.fileExists(atPath: packageSwift.path) {
                    let sourceResources = target.sourceResourceComponents.reduce(current) {
                        $0.appendingPathComponent($1)
                    }
                    appendIfExists(sourceResources)
                    return
                }

                let parent = current.deletingLastPathComponent()
                if parent.path == current.path {
                    return
                }
                current = parent
            }
        }

        appendBundleRoots(in: mainResourceURL)
        appendIfExists(mainResourceURL)

        if let executableURL {
            let executableDirectory = executableURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .deletingLastPathComponent()
            let siblingResources = executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")

            appendBundleRoots(in: executableDirectory)
            appendBundleRoots(in: siblingResources)
            appendIfExists(siblingResources)
            appendIfExists(executableDirectory.appendingPathComponent("Resources"))
            appendIfExists(executableDirectory)
            if allowSourceFallback {
                appendSourceResources(from: executableDirectory)
            }
        }

        if allowSourceFallback {
            appendSourceResources(from: currentWorkingDirectoryURL)
        }
        return roots
    }

    private static func shouldAllowSourceFallback(
        mainResourceURL: URL?,
        executableURL: URL?
    ) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if let executableName = executableURL?.lastPathComponent,
           executableName == "xctest" || executableName == "swiftpm-testing-helper" {
            return true
        }
        if isInsideXCTestBundle(mainResourceURL) || isInsideXCTestBundle(executableURL) {
            return true
        }
        return !isInsideAppBundle(mainResourceURL) && !isInsideAppBundle(executableURL)
    }

    private static func isInsideAppBundle(_ url: URL?) -> Bool {
        guard var current = url?.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }

        for _ in 0..<12 {
            if current.pathExtension == "app" {
                return true
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return false
            }
            current = parent
        }

        return false
    }

    private static func isInsideXCTestBundle(_ url: URL?) -> Bool {
        guard var current = url?.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }

        for _ in 0..<12 {
            if current.pathExtension == "xctest" {
                return true
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return false
            }
            current = parent
        }

        return false
    }

    private static func defaultExecutableURL() -> URL? {
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }

        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: executablePath)
    }

    private static func defaultCurrentWorkingDirectoryURL(fileManager: FileManager) -> URL? {
        let path = fileManager.currentDirectoryPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
