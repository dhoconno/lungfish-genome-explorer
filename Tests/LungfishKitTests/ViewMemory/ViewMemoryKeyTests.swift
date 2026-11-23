// ViewMemoryKeyTests.swift - Which moves keep an item's view memory key and which drop it (VS A3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import XCTest
@testable import LungfishKit

final class ViewMemoryKeyTests: XCTestCase {
    private func key(of bundle: URL, in project: URL, storeRoot: URL) throws -> ViewMemoryKey {
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)
        return try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: bundle)))
    }

    func testARenamedOrMovedProjectKeepsItsKeys() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let before = try key(of: fixture.bundle, in: fixture.project, storeRoot: fixture.storeRoot)

        let renamed = fixture.base.appendingPathComponent("Renamed.lungfish", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.project, to: renamed)
        let renamedBundle = renamed.appendingPathComponent("Analyses/run.lungfish12s", isDirectory: true)
        XCTAssertEqual(try key(of: renamedBundle, in: renamed, storeRoot: fixture.storeRoot), before)

        let parent = fixture.base.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let moved = parent.appendingPathComponent("Renamed.lungfish", isDirectory: true)
        try FileManager.default.moveItem(at: renamed, to: moved)
        let movedBundle = moved.appendingPathComponent("Analyses/run.lungfish12s", isDirectory: true)
        XCTAssertEqual(try key(of: movedBundle, in: moved, storeRoot: fixture.storeRoot), before)
    }

    func testACopiedProjectAndARenamedBundleGetOtherKeys() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let before = try key(of: fixture.bundle, in: fixture.project, storeRoot: fixture.storeRoot)

        let copy = fixture.base.appendingPathComponent("Walk copy.lungfish", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.project, to: copy)
        let copiedBundle = copy.appendingPathComponent("Analyses/run.lungfish12s", isDirectory: true)
        XCTAssertNotEqual(try key(of: copiedBundle, in: copy, storeRoot: fixture.storeRoot), before)

        let renamedBundle = fixture.bundle.deletingLastPathComponent()
            .appendingPathComponent("renamed.lungfish12s", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.bundle, to: renamedBundle)
        XCTAssertNotEqual(try key(of: renamedBundle, in: fixture.project, storeRoot: fixture.storeRoot), before)
    }

    func testThePrivateAndPlainSpellingsOfOnePathKeyAlike() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let path = fixture.bundle.path
        let other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        let plain = ViewMemoryItem.read(at: fixture.bundle)
        let spelled = ViewMemoryItem.read(at: URL(fileURLWithPath: other, isDirectory: true))
        XCTAssertEqual(plain.path, "Analyses/run.lungfish12s")
        XCTAssertEqual(spelled.path, plain.path)
        XCTAssertEqual(spelled.projectRoot, plain.projectRoot)
    }

    func testAPathIsKeyedInNFC() throws {
        let fixture = try ViewMemoryFixture(bundleName: "Caf\u{E9}.lungfish12s")
        defer { fixture.cleanup() }
        let decomposed = fixture.bundle.deletingLastPathComponent()
            .appendingPathComponent("Cafe\u{301}.lungfish12s", isDirectory: true)
        let item = ViewMemoryItem.read(at: decomposed)
        XCTAssertEqual(item.path.unicodeScalars.count, "Analyses/Caf\u{E9}.lungfish12s".unicodeScalars.count)
        XCTAssertEqual(try key(of: decomposed, in: fixture.project, storeRoot: fixture.storeRoot),
                       try key(of: fixture.bundle, in: fixture.project, storeRoot: fixture.storeRoot))
    }

    func testAFileOutsideAnyProjectKeysOnItsPathOnceTheLooseFolderIsRead() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let loose = fixture.base.appendingPathComponent("loose.fasta")
        try Data(">a\nACGT\n".utf8).write(to: loose)
        let item = ViewMemoryItem.read(at: loose)
        XCTAssertNil(item.projectRoot)
        XCTAssertNotNil(item.folder)
        let store = ViewMemoryStore(root: fixture.storeRoot)
        XCTAssertNil(store.key(for: item))
        store.loadLoose()
        XCTAssertEqual(store.key(for: item)?.folder, ViewMemoryKey.looseFolder)
    }

    func testTheRootTextUsesTheVolumeAndNeverTheDeviceNumber() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let canonical = ViewMemoryItem.canonical(fixture.project)
        let identity = try ProjectRoot.rootIdentity(at: canonical)
        let text = ViewMemoryKey.rootText(identity: identity, canonicalRoot: canonical)
        XCTAssertFalse(text.contains("device:"))
        XCTAssertTrue(text.hasPrefix("volume:") || text.hasPrefix("path:\(canonical.path)|"))
    }
}
