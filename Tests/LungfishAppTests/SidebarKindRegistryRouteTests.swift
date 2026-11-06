// SidebarKindRegistryRouteTests.swift - Kinds open from the sidebar through SidebarKindRegistry (Phase 3.2 lane SIDEBAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Plan step 6 and program exit check 4. A stub bundle kind and a stub surface, both defined here, open from the
// sidebar with no App edit beyond their two registrations. A legacy NVD result with no analysis-metadata.json still
// lists and opens through the registry's read-only fallback, and nothing is written into it. Each test scans as the
// sidebar does, builds the row from the scan node and opens it with `displayContent(for:)`. The test methods are
// synchronous and wait by turning the main run loop, as in `NvdSurfaceRouteTests`.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishNvdUI

/// A surface that shows a plain view and keeps the input it was given.
@MainActor
private final class StubKindSurface: ResultViewport {
    let controller = NSViewController()
    private(set) var loadedURL: URL?
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(SidebarKindRegistryRouteTests.stubBundleKind) }

    init() { controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        loadedURL = try expectInput(input, as: URL.self)
    }
}

@MainActor
final class SidebarKindRegistryRouteTests: XCTestCase {
    nonisolated static let stubBundleKind = BundleKindID(rawValue: "sidebar-stub-test")
    private static let stubKindID = "bundle:sidebar-stub-test"

    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var hostDefaults: HostDefaultsRestorer?
    private var legacyNvd: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "sidebar-kind-route")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        NvdResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "SidebarKindRegistryRouteTests").defaults
        let imports = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Imports", isDirectory: true))
        legacyNvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-legacy-run", in: imports).bundle
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        SidebarKindRegistry.unregister(id: Self.stubKindID)
        window.contentViewController = nil
        window = nil
        controller = nil
        NvdResultViewController.testMetadataUserDefaultsOverride = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// A stub kind lists as its own row and opens in its own surface, from two registrations and nothing else.
    func testAStubBundleKindOpensFromTheSidebarThroughRegistrationAlone() throws {
        let bundleURL = root.appendingPathComponent("Stub Sample.lungfishsidebarstub", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("stub-manifest.json"))

        SidebarKindRegistry.register(Self.stubDescriptor())
        controller.viewerController.surfaceHost.registry.register(.bundle(Self.stubBundleKind)) { StubKindSurface() }

        let node = SidebarProjectScanner.scanTree(from: bundleURL)
        XCTAssertEqual(node.type, .registeredBundle)
        XCTAssertEqual(node.title, "Stub Sample", "a bundle row drops its folder extension")
        XCTAssertEqual(node.badge, .symbol("star.square"))
        XCTAssertTrue(node.children.isEmpty, "a bundle row never lists the files inside it")

        controller.displayContent(for: row(from: node))
        let opened = waitUntilOnRunLoop(budget: .lookup) {
            self.controller.viewerController.installedSurface is StubKindSurface
        }
        XCTAssertTrue(opened, "the stub kind never opened in its registered surface")
        let surface = controller.viewerController.installedSurface as? StubKindSurface
        XCTAssertEqual(surface?.loadedURL?.standardizedFileURL, bundleURL.standardizedFileURL)
    }

    /// The same folder without the manifest its kind requires lists as a document and never opens the stub surface.
    func testAStubFolderWithoutItsManifestListsAsADocument() throws {
        let bundleURL = root.appendingPathComponent("Empty.lungfishsidebarstub", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        SidebarKindRegistry.register(Self.stubDescriptor())

        let node = SidebarProjectScanner.scanTree(from: bundleURL)
        XCTAssertEqual(node.type, .document)
        XCTAssertNil(node.userInfo[SidebarItemType.registeredKindKey])
    }

    /// A legacy NVD result with no analysis-metadata.json lists by its old name prefix, opens in the NVD viewer, and
    /// keeps every file as it was.
    func testALegacyNvdResultWithNoMetadataOpensAndIsNotWrittenTo() throws {
        let legacy: URL = legacyNvd
        let imports = legacy.deletingLastPathComponent()
        XCTAssertNil(AnalysesFolder.readAnalysisMetadata(from: legacy), "the fixture must have no metadata sidecar")
        let before = try Self.snapshot(of: legacy)

        XCTAssertEqual(SidebarKindRegistry.analysisKind(ofFolder: legacy)?.id, "analysis:nvd")
        let nodes = SidebarProjectScanner.collectNvdResults(in: imports)
        XCTAssertEqual(nodes.map(\.type), [.nvdResult])
        let node = try XCTUnwrap(nodes.first)

        controller.displayContent(for: row(from: node))
        let opened = waitUntilOnRunLoop(budget: .lookup) {
            self.controller.viewerController.installedSurface?.surfaceKind == .analysis(.nvd)
                && self.controller.inspectorController.viewModel.documentSectionViewModel.nvdManifest != nil
        }
        XCTAssertTrue(opened, "the legacy NVD result never opened")
        XCTAssertEqual(try Self.snapshot(of: legacy), before, "opening a legacy result wrote into it")
    }

    /// Every viewport a built-in kind names has a factory in the viewer's surface registry, and every bundle kind's
    /// row is a bundle row.
    func testEveryBuiltInKindNamesAViewportTheViewerRegisters() {
        let registry = controller.viewerController.makeSurfaceRegistry()
        for kind in SidebarKindRegistry.bundleKinds + SidebarKindRegistry.analysisKinds {
            if case .bundle = kind.recognition {
                XCTAssertTrue(SidebarItemType(kind.rowType).isBundle, "\(kind.id) lists as a bundle row")
            }
            guard let viewport = kind.viewport else { continue }
            let surfaceKind: SurfaceKind = switch viewport {
            case .bundle(let id): .bundle(id)
            case .analysis(let id): .analysis(id)
            case .view(let id): .view(SurfaceViewID(rawValue: id))
            }
            XCTAssertTrue(registry.isRegistered(surfaceKind), "\(kind.id) opens \(surfaceKind), which has no factory")
        }
    }

    // MARK: - Helpers

    private static func stubDescriptor() -> SidebarKindDescriptor {
        let bundle = BundleKindDescriptor(
            id: stubBundleKind, role: .bundle, folderExtensions: ["lungfishsidebarstub"],
            manifestFileName: "stub-manifest.json", recognition: .extensionAndManifest, utTypeIdentifier: nil,
            sidebarSymbolName: "star.square", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true), copy: .refused,
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: [])
        return SidebarKindDescriptor(
            id: stubKindID, recognition: .bundle(bundle, manifestRequired: true), rowType: .registeredBundle,
            sidebarSymbolName: "star.square", displayName: "Stub result", viewport: .bundle(stubBundleKind))
    }

    /// The row the sidebar makes from a scan node.
    private func row(from node: SidebarScanNode) -> SidebarItem {
        let item = SidebarItem(title: node.title, type: node.type, url: node.url)
        item.userInfo = node.userInfo
        return item
    }

    /// Each file under `url` by relative path, with its size and modification date.
    private static func snapshot(of url: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: Set(keys))
            let path = String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count))
            files[path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return files
    }
}
