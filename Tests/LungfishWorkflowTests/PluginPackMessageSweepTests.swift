// PluginPackMessageSweepTests.swift - Every pack named in a user-facing message exists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// Missing-tool messages tell the user which pack to install. A pack name
/// that is not in the registry sends them hunting for something the Plugin
/// Manager does not list (the old "Alignment plugin pack" for minimap2).
/// This sweep reads every Swift source under `Sources/` and checks each
/// "... the <Name> pack" phrase against the registry's ids and display names.
final class PluginPackMessageSweepTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Matches "Install the Genome Assembly pack", "Reinstall the PCR Primer
    /// Design plugin pack", "repair the Metagenomics pack", and id-style
    /// "the read-mapping plugin pack" or "the wastewater-surveillance tool
    /// pack". The name is one to five words.
    private static let phrase = try! NSRegularExpression(
        pattern: #"\bthe ((?:[A-Z][A-Za-z0-9-]*|[a-z0-9]+(?:-[a-z0-9]+)+)(?: [A-Za-z0-9-]+){0,4}?) (?:plugin |tool )?pack\b"#
    )

    func testEveryPackNamedInSourceMessagesExistsInRegistry() throws {
        let known = Set(
            PluginPack.builtIn.flatMap { [$0.id, $0.name] }
                + [PluginPack.requiredSetupPack.id, PluginPack.requiredSetupPack.name]
        ).map { $0.lowercased() }
        let knownSet = Set(known)

        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        var unknown: [String] = []
        var matched = 0
        for fileURL in try repositoryFiles(under: sourcesRoot) {
            let text = try readRepositorySource(fileURL)
            guard text.contains(" pack") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.phrase.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[nameRange])
                matched += 1
                if !knownSet.contains(name.lowercased()) {
                    let relative = fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                    unknown.append("\(relative): \"\(name)\"")
                }
            }
        }

        XCTAssertGreaterThan(matched, 0, "the sweep should find at least one pack reference under Sources/")
        XCTAssertTrue(
            unknown.isEmpty,
            "Pack names not in PluginPack.builtIn (id or display name):\n" + unknown.joined(separator: "\n")
        )
    }

    func testSweepRegexRecognisesRegistryPhrasings() {
        func name(in text: String) -> String? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = Self.phrase.firstMatch(in: text, range: range),
                  let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
        XCTAssertEqual(name(in: "Install the Genome Assembly pack to enable SPAdes."), "Genome Assembly")
        XCTAssertEqual(name(in: "Reinstall the PCR Primer Design plugin pack."), "PCR Primer Design")
        XCTAssertEqual(name(in: "Install or repair the Metagenomics pack and try again."), "Metagenomics")
        XCTAssertEqual(name(in: "Install the read-mapping plugin pack first."), "read-mapping")
        XCTAssertEqual(name(in: "Run Freyja through the wastewater-surveillance tool pack."), "wastewater-surveillance")
        XCTAssertEqual(name(in: "Install the Full-length MHC Genotyping pack in Plugin Manager."), "Full-length MHC Genotyping")
        XCTAssertEqual(name(in: "Install the Alignment plugin pack from the Plugin Manager."), "Alignment")
        XCTAssertNil(name(in: "Offline pack must be a directory."))
    }

    func testMinimap2MissingToolMessageNamesTheReadMappingPack() {
        let message = Minimap2PipelineError.minimap2NotInstalled.localizedDescription
        XCTAssertTrue(message.contains("Read Mapping plugin pack"), message)
        XCTAssertFalse(message.contains("Alignment plugin pack"), message)
        XCTAssertEqual(PluginPack.builtInPack(id: "read-mapping")?.name, "Read Mapping")
    }
}
