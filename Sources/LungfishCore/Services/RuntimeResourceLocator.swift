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
            fileManager: .default,
            allowSourceFallback: false
        )
    }

    public static func resourceRoots(for target: RuntimeResourceTarget) -> [URL] {
        resourceRoots(
            for: target,
            mainResourceURL: Bundle.main.resourceURL,
            executableURL: defaultExecutableURL(),
            currentWorkingDirectoryURL: defaultCurrentWorkingDirectoryURL(fileManager: .default),
            fileManager: .default,
            allowSourceFallback: false
        )
    }

    static func path(
        _ relativePath: String,
        in target: RuntimeResourceTarget,
        mainResourceURL: URL?,
        executableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        fileManager: FileManager,
        allowSourceFallback: Bool = false
    ) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }

        for resourceRoot in resourceRoots(
            for: target,
            mainResourceURL: mainResourceURL,
            executableURL: executableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL,
            fileManager: fileManager,
            allowSourceFallback: allowSourceFallback
        ) {
            let canonicalRoot = resourceRoot.resolvingSymlinksInPath().standardizedFileURL
            let candidate = canonicalRoot
                .appendingPathComponent(relativePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if isStrictDescendant(candidate, of: canonicalRoot),
               fileManager.fileExists(atPath: candidate.path) {
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
        fileManager: FileManager,
        allowSourceFallback: Bool = false
    ) -> [URL] {
        var roots: [URL] = []
        var seenPaths = Set<String>()
        if !allowSourceFallback,
           containsCaseAliasedAppBundle(mainResourceURL) || containsCaseAliasedAppBundle(executableURL) {
            return []
        }
        let appBundleURL = allowSourceFallback
            ? nil
            : (containingAppBundle(mainResourceURL) ?? containingAppBundle(executableURL))
        let rawAppResourcesURL = appBundleURL?
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .standardizedFileURL
        let canonicalAppResourcesURL = rawAppResourcesURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL

        func appendIfExists(_ url: URL?) {
            guard let url else { return }
            let rawURL = url.standardizedFileURL
            let normalized = url.resolvingSymlinksInPath().standardizedFileURL
            if let rawAppResourcesURL, let canonicalAppResourcesURL {
                guard isContained(rawURL, in: rawAppResourcesURL),
                      isContained(normalized, in: canonicalAppResourcesURL) else {
                    return
                }
            }
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

    private static func containingAppBundle(_ url: URL?) -> URL? {
        guard var current = url?.standardizedFileURL else {
            return nil
        }

        for _ in 0..<12 {
            if current.pathExtension == "app" {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }

        return nil
    }

    private static func containsCaseAliasedAppBundle(_ url: URL?) -> Bool {
        guard var current = url?.standardizedFileURL else { return false }

        for _ in 0..<12 {
            let pathExtension = current.pathExtension
            if pathExtension.lowercased() == "app" {
                return pathExtension != "app"
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
        return false
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path || isStrictDescendant(candidate, of: root)
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
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
