import Foundation
import Testing
@testable import LungfishCore

struct RuntimeResourceLocatorTests {

    @Test
    func defaultLocatorResolvesSwiftPMTestResourcesWithoutProductionFallback() {
        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow
        )

        #expect(resolved != nil)
    }

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
    func resolvesPrefixedSwiftPMResourceBundleWhenLegacyHintsAreAbsent() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-xctest-\(UUID().uuidString)", isDirectory: true)
        let products = tempRoot.appendingPathComponent("debug", isDirectory: true)
        let testBundle = products.appendingPathComponent("LungfishPackageTests.xctest", isDirectory: true)
        let expected = products
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle", isDirectory: true)
            .appendingPathComponent("Tools/tool-versions.json")
        try FileManager.default.createDirectory(at: testBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: expected)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        #expect(FileManager.default.fileExists(
            atPath: products.appendingPathComponent("LungfishWorkflow.bundle").path) == false)

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default,
            testBundleURLs: [testBundle]
        )

        #expect(resolved?.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test
    func rejectsCaseAliasedXCTestBundleAndUnknownSiblingBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-xctest-case-\(UUID().uuidString)", isDirectory: true)
        let products = tempRoot.appendingPathComponent("debug", isDirectory: true)
        let testBundle = products.appendingPathComponent("LungfishPackageTests.XCTEST", isDirectory: true)
        let unexpected = products
            .appendingPathComponent("Unexpected_LungfishWorkflow.bundle", isDirectory: true)
            .appendingPathComponent("Tools/tool-versions.json")
        try FileManager.default.createDirectory(at: testBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: unexpected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: unexpected)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default,
            testBundleURLs: [testBundle]
        )

        #expect(resolved == nil)
    }

    @Test
    func rejectsSymlinkedXCTestProductRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-xctest-root-link-\(UUID().uuidString)", isDirectory: true)
        let realProducts = tempRoot.appendingPathComponent("real-debug", isDirectory: true)
        let linkedProducts = tempRoot.appendingPathComponent("linked-debug", isDirectory: true)
        let testBundle = linkedProducts.appendingPathComponent("LungfishPackageTests.xctest", isDirectory: true)
        let resource = realProducts
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle", isDirectory: true)
            .appendingPathComponent("Tools/tool-versions.json")
        try FileManager.default.createDirectory(
            at: realProducts.appendingPathComponent("LungfishPackageTests.xctest", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: resource)
        try FileManager.default.createSymbolicLink(at: linkedProducts, withDestinationURL: realProducts)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default,
            testBundleURLs: [testBundle]
        )

        #expect(resolved == nil)
    }

    @Test
    func rejectsSymlinkedXCTestSiblingResourceBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-xctest-bundle-link-\(UUID().uuidString)", isDirectory: true)
        let products = tempRoot.appendingPathComponent("debug", isDirectory: true)
        let testBundle = products.appendingPathComponent("LungfishPackageTests.xctest", isDirectory: true)
        let outsideBundle = tempRoot.appendingPathComponent("outside.bundle", isDirectory: true)
        let outsideResource = outsideBundle.appendingPathComponent("Tools/tool-versions.json")
        let linkedBundle = products.appendingPathComponent(
            "LungfishGenomeBrowser_LungfishWorkflow.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outsideResource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: outsideResource)
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: outsideBundle)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = RuntimeResourceLocator.path(
            "Tools/tool-versions.json",
            in: .workflow,
            mainResourceURL: nil,
            executableURL: nil,
            currentWorkingDirectoryURL: nil,
            fileManager: .default,
            testBundleURLs: [testBundle]
        )

        #expect(resolved == nil)
    }

    @Test
    func processMarkersDoNotEnableCheckoutFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-marker-spoof-\(UUID().uuidString)", isDirectory: true)
        let resource = tempRoot.appendingPathComponent(
            "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
        )
        try FileManager.default.createDirectory(
            at: resource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("// swift-tools-version: 6.2\n".utf8).write(
            to: tempRoot.appendingPathComponent("Package.swift")
        )
        try Data("{}".utf8).write(to: resource)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for executableName in ["xctest", "swiftpm-testing-helper"] {
            let resolved = RuntimeResourceLocator.path(
                "Tools/tool-versions.json",
                in: .workflow,
                mainResourceURL: nil,
                executableURL: tempRoot.appendingPathComponent(executableName),
                currentWorkingDirectoryURL: tempRoot,
                fileManager: .default,
                testBundleURLs: []
            )
            #expect(resolved == nil)
        }

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LungfishCore/Services/RuntimeResourceLocator.swift"),
            encoding: .utf8
        )
        #expect(source.contains("XCTestConfigurationFilePath") == false)
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

    /// Phase 3.3 lane CLISYM, row CLI-SYMLINK-LOCK (walk W-35). A command-line tool run through a symlink, which is how a
    /// person installs one on PATH, reports the link as its executable and the link's folder as its resources, so the app
    /// that holds the binary was never found and `taxtriage run` refused with exit 126 and "the tool lock has no pinned
    /// version". The lookup starts from the binary the link names.
    @Test("A tool lock lookup through a symlink finds the lock beside the binary")
    func testToolLockLookupThroughASymlinkFindsTheLockBesideTheBinary() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-cli-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let appContents = tempRoot.appendingPathComponent("Lungfish.app/Contents", isDirectory: true)
        let binary = appContents.appendingPathComponent("MacOS/lungfish-cli")
        let lock = appContents
            .appendingPathComponent("Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle")
            .appendingPathComponent("Contents/Resources/ManagedTools/third-party-tools-lock.json")
        let linkFolder = tempRoot.appendingPathComponent("usr-local-bin", isDirectory: true)
        let link = linkFolder.appendingPathComponent("lungfish-cli")
        for folder in [binary.deletingLastPathComponent(), lock.deletingLastPathComponent(), linkFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try "{}".write(to: lock, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        // What Bundle.main reports. Run directly, it names the app's own folders. Run through the link, it names the link
        // and the link's folder (checked on this Mac with a probe tool built into an app folder and linked from another).
        func lookup(executable: URL, resources: URL) -> URL? {
            RuntimeResourceLocator.path(
                "ManagedTools/third-party-tools-lock.json",
                in: .workflow,
                mainResourceURL: resources,
                executableURL: executable,
                currentWorkingDirectoryURL: nil,
                fileManager: .default
            )
        }
        let expected = lock.resolvingSymlinksInPath().path
        let direct = lookup(executable: binary, resources: appContents.appendingPathComponent("Resources", isDirectory: true))
        #expect(direct?.resolvingSymlinksInPath().path == expected, "the binary itself finds the lock")
        let linked = lookup(executable: link, resources: linkFolder)
        #expect(linked?.resolvingSymlinksInPath().path == expected, "a link to the binary finds the lock beside the binary")
    }

    /// Resolving the link must not widen the search. A link to a binary that sits in no app has no lock beside it to find,
    /// as a binary that sits there with no link has none (`standaloneCLIHasNoImplicitAdjacentSwiftPMBundleFallback`).
    @Test("A symlink to a binary that sits in no app finds no lock")
    func linkToABinaryOutsideAnyAppFindsNoLock() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-resource-cli-stray-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let strayFolder = tempRoot.appendingPathComponent("stray", isDirectory: true)
        let stray = strayFolder.appendingPathComponent("lungfish-cli")
        let beside = strayFolder
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle")
            .appendingPathComponent("ManagedTools/third-party-tools-lock.json")
        let linkFolder = tempRoot.appendingPathComponent("usr-local-bin", isDirectory: true)
        let link = linkFolder.appendingPathComponent("lungfish-cli")
        for folder in [beside.deletingLastPathComponent(), linkFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: stray)
        try "{}".write(to: beside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stray)

        let found = RuntimeResourceLocator.path(
            "ManagedTools/third-party-tools-lock.json",
            in: .workflow,
            mainResourceURL: linkFolder,
            executableURL: link,
            currentWorkingDirectoryURL: nil,
            fileManager: .default
        )

        #expect(found == nil, "a lock beside a binary that sits in no app is not a lock")
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
