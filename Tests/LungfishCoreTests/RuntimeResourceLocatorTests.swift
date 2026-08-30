import Foundation
import Testing
@testable import LungfishCore

struct RuntimeResourceLocatorTests {

    @Test
    func explicitTestFallbackResolvesSwiftPMTestResources() {
        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: Bundle.main.resourceURL,
            executableURL: Bundle.main.executableURL,
            currentWorkingDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            fileManager: .default,
            allowSourceFallback: true
        )

        #expect(resolved != nil)
    }

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
            fileManager: .default,
            allowSourceFallback: true
        )

        #expect(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test
    func standaloneCLIHasNoImplicitCheckoutFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-cli-\(UUID().uuidString)", isDirectory: true)
        let repositoryRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let executable = repositoryRoot.appendingPathComponent(".build/debug/lungfish-cli")
        let expected = repositoryRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: expected)
        try Data("// swift-tools-version: 6.2\n".utf8).write(
            to: repositoryRoot.appendingPathComponent("Package.swift")
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: executable,
            currentWorkingDirectoryURL: repositoryRoot,
            fileManager: .default
        )

        #expect(resolved == nil)
    }

    @Test
    func standaloneCLIHasNoImplicitAdjacentSwiftPMBundleFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-adjacent-cli-\(UUID().uuidString)", isDirectory: true)
        let debugDirectory = tempRoot.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        let executable = debugDirectory.appendingPathComponent("lungfish-cli")
        let adjacentBundle = debugDirectory
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle", isDirectory: true)
        let leakedResource = adjacentBundle.appendingPathComponent("Tools/tool-versions.json")
        try FileManager.default.createDirectory(
            at: leakedResource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: leakedResource)
        try Data("executable".utf8).write(to: executable)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: executable,
            currentWorkingDirectoryURL: tempRoot,
            fileManager: .default
        )

        #expect(resolved == nil)
    }

    @Test
    func rejectsUnsafeRelativeResourcePaths() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-path-\(UUID().uuidString)", isDirectory: true)
        let appResources = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/Contents/Resources",
            isDirectory: true
        )
        let appExecutable = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/Contents/MacOS/Lungfish"
        )
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outside = tempRoot.appendingPathComponent("outside.json")
        let contentsOutside = appResources.deletingLastPathComponent().appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        try Data("outside".utf8).write(to: contentsOutside)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for relativePath in ["", outside.path, "../outside.json", "Tools/../../outside.json"] {
            let resolved = RuntimeResourceLocator.path(
                relativePath,
                in: .workflow,
                mainResourceURL: appResources,
                executableURL: appExecutable,
                currentWorkingDirectoryURL: nil,
                fileManager: .default
            )

            #expect(resolved == nil)
        }
    }

    @Test
    func appResourceLookupRejectsSymlinkEscape() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-symlink-\(UUID().uuidString)", isDirectory: true)
        let appResources = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/Contents/Resources",
            isDirectory: true
        )
        let appExecutable = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/Contents/MacOS/Lungfish"
        )
        let outside = tempRoot.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: appResources.appendingPathComponent("escape.json"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "escape.json",
            in: .workflow,
            mainResourceURL: appResources,
            executableURL: appExecutable,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved == nil)
    }

    @Test
    func appResourceLookupRejectsSymlinkedResourcesRootOutsideWrapper() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-root-symlink-\(UUID().uuidString)", isDirectory: true)
        let appContents = tempRoot.appendingPathComponent("Lungfish Debug.app/Contents", isDirectory: true)
        let appResources = appContents.appendingPathComponent("Resources", isDirectory: true)
        let appExecutable = appContents.appendingPathComponent("MacOS/Lungfish")
        let outsideResources = tempRoot.appendingPathComponent("outside-resources", isDirectory: true)
        let outsideResource = outsideResources.appendingPathComponent("Tools/tool-versions.json")
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideResource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: outsideResource)
        try FileManager.default.createSymbolicLink(at: appResources, withDestinationURL: outsideResources)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: appResources,
            executableURL: appExecutable,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved == nil)
    }

    @Test
    func appResourceLookupRequiresExactContentsResourcesRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-case-\(UUID().uuidString)", isDirectory: true)
        let aliasedResources = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/contents/resources",
            isDirectory: true
        )
        let aliasedExecutable = tempRoot.appendingPathComponent(
            "Lungfish Debug.app/contents/MacOS/Lungfish"
        )
        let resource = aliasedResources.appendingPathComponent("escape.json")
        try FileManager.default.createDirectory(
            at: aliasedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: aliasedResources, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: resource)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "escape.json",
            in: .workflow,
            mainResourceURL: aliasedResources,
            executableURL: aliasedExecutable,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved == nil)
    }

    @Test
    func appResourceLookupRejectsWrapperCaseAlias() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-wrapper-case-\(UUID().uuidString)", isDirectory: true)
        let appResources = tempRoot.appendingPathComponent(
            "Lungfish Debug.APP/Contents/Resources",
            isDirectory: true
        )
        let appExecutable = tempRoot.appendingPathComponent(
            "Lungfish Debug.APP/Contents/MacOS/Lungfish"
        )
        let resource = appResources.appendingPathComponent("escape.json")
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: resource)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "escape.json",
            in: .workflow,
            mainResourceURL: appResources,
            executableURL: appExecutable,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(resolved == nil)
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

    @Test
    func doesNotUseWorkspaceFallbackWhenRunningFromAppBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-locator-\(UUID().uuidString)", isDirectory: true)
        let repositoryRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let workingDirectory = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        let appExecutable = tempRoot.appendingPathComponent("Lungfish.app/Contents/MacOS/Lungfish")
        let appResources = tempRoot.appendingPathComponent("Lungfish.app/Contents/Resources", isDirectory: true)
        let sourceFallback = repositoryRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/micromamba")

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceFallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "binary".write(to: sourceFallback, atomically: true, encoding: .utf8)
        try "swift-tools-version: 6.2\n".write(
            to: repositoryRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/micromamba",
            in: .workflow,
            mainResourceURL: appResources,
            executableURL: appExecutable,
            currentWorkingDirectoryURL: workingDirectory,
            fileManager: .default
        )

        #expect(resolved == nil)
    }
}
