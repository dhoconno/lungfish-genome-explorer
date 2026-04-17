import Foundation
import Testing
@testable import LungfishCore

struct RuntimeResourceLocatorTests {

    @Test
    func resolvesWorkflowResourcesFromNestedAppBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-locator-\(UUID().uuidString)", isDirectory: true)
        let appResources = tempRoot.appendingPathComponent("Lungfish.app/Contents/Resources", isDirectory: true)
        let expected = appResources
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle")
            .appendingPathComponent("Contents/Resources/Tools/tool-versions.json")
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}".write(to: expected, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: appResources,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test
    func resolvesWorkflowResourcesFromWorkspaceFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-locator-\(UUID().uuidString)", isDirectory: true)
        let repositoryRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let workingDirectory = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        let expected = repositoryRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/micromamba")

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "binary".write(to: expected, atomically: true, encoding: .utf8)
        try "swift-tools-version: 6.2\n".write(
            to: repositoryRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/micromamba",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: nil,
            currentWorkingDirectoryURL: workingDirectory,
            fileManager: .default
        )

        #expect(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test
    func resolvesAppResourcesFromMainBundleRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-locator-\(UUID().uuidString)", isDirectory: true)
        let appResources = tempRoot.appendingPathComponent("Lungfish.app/Contents/Resources", isDirectory: true)
        let expected = appResources.appendingPathComponent("Help/index.md")
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Help\n".write(to: expected, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Help/index.md",
            in: .app,
            mainResourceURL: appResources,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path)
    }
}
