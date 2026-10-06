// FeaturesYAMLMenuPathTests.swift - The menu paths in features.yaml name real menu items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/user-manual/features.yaml is the manual pipeline's ground truth for GUI entry
// points. scripts/checks/features-yaml-entry-points.py checks only the second segment of
// a path against titles it finds in the menu source, so a path that names an item in the
// wrong submenu still passes. After the Tools menu was regrouped, "Tools > Mapping > Viral
// Recon" and "Tools > Search Online Databases > Search NCBI" named places those items no
// longer are. This suite builds the real menu bar and resolves every menu path in the file
// one segment at a time.
//
// A path is a menu path when its first segment is the title of a menu in the bar. The
// application menu is skipped, because its title is the name of the release channel. The
// walk stops at the first item that has no submenu, because the segments after it name
// things inside the window that item opens, for example "Tools > Plugin Manager… >
// wastewater-surveillance". A path may end on a submenu, which is how a feature that is
// reached through a whole category names it. A trailing ellipsis never counts when titles
// are compared.

import AppKit
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class FeaturesYAMLMenuPathTests: XCTestCase {
    // MARK: - The file against the real menu bar

    /// Every entry point of features.yaml that starts with a menu of the bar resolves,
    /// with every catalog workflow enabled and no linked package. Every path that does not
    /// is reported with the feature that lists it.
    func testEveryMenuPathInFeaturesYAMLResolvesAgainstTheRealMenuBar() throws {
        let (entries, readerProblems) = FeaturesYAMLEntryPoints.read(try readRepositoryFile("docs/user-manual/features.yaml"))
        XCTAssertEqual(readerProblems, [], "features.yaml writes entry_points as block lists of strings")

        try withMainMenu { bar in
            var checked = 0
            var unresolved: [String] = []
            for entry in entries {
                let segments = MenuPathWalker.segments(of: entry.path)
                guard MenuPathWalker.startsAtMenu(of: bar, segments) else { continue }
                checked += 1
                guard case .missing(let segment, let parents, let available) = MenuPathWalker.resolve(segments, in: bar) else { continue }
                let place = parents.isEmpty ? "the menu bar" : parents.joined(separator: " > ")
                var line = "\(entry.featureID): \"\(entry.path)\" names \"\(segment)\", which is not in \(place) "
                    + "(it holds \(available.joined(separator: ", ")))."
                let elsewhere = MenuPathWalker.locations(of: segment, in: bar)
                if !elsewhere.isEmpty {
                    line += " The menu has it at \(elsewhere.joined(separator: " or "))."
                }
                unresolved.append(line)
            }
            // A reader that silently found nothing would pass every path.
            XCTAssertGreaterThan(entries.count, 100, "the reader found the entry_points blocks")
            XCTAssertGreaterThan(checked, 30, "the reader found the menu paths among them")
            XCTAssertTrue(
                unresolved.isEmpty,
                "\(unresolved.count) features.yaml menu path(s) do not resolve\n" + unresolved.joined(separator: "\n")
            )
        }
    }

    /// The paths this suite exists to catch, against the real bar. The quick script passes
    /// most of the old paths, because their second segment is a title the menu source still
    /// holds somewhere.
    func testTheRealBarResolvesTheMovedItemsAndRefusesTheirOldPaths() throws {
        try withMainMenu { bar in
            @MainActor func resolves(_ path: String) -> Bool {
                if case .resolved = MenuPathWalker.resolve(MenuPathWalker.segments(of: path), in: bar) { return true }
                return false
            }
            for path in [
                "File > Search Online Databases > Search NCBI…",
                "Tools > Variant Calling > Call Variants…",
                "Tools > Variant Calling > Viral Recon (SARS-CoV-2)…",
                "Tools > Alignment & Phylogenetics > MAFFT…",
                "Tools > Workflows",
                "Tools > Plugin Manager… > wastewater-surveillance",
                "Selection > Genotype Call > Clear Review",
                "File > Export > Provenance > Methods Section…",
            ] {
                XCTAssertTrue(resolves(path), "\(path) is in the menu")
            }
            for path in [
                "Tools > Search Online Databases > Search NCBI...",
                "Tools > Call Variants…",
                "Tools > Mapping > Viral Recon…",
                "Tools > Multiple Sequence Alignment > MAFFT…",
                "Tools > Genotype Review > Selected Cell",
                "Tools > Workflows > <package name>…",
                "File > Export > Methods Section",
            ] {
                XCTAssertFalse(resolves(path), "\(path) names a place the menu no longer has")
            }
        }
    }

    /// The quick pre-push script and this suite decide what a menu path is from the same
    /// list of menus, so a new menu in the bar teaches both.
    func testTheQuickCheckScriptKnowsEveryMenuOfTheBar() throws {
        let script = try readRepositoryFile("scripts/checks/features-yaml-entry-points.py")
        let declaration = try XCTUnwrap(
            script.range(of: #"TOP_LEVEL_MENUS = \{[^}]*\}"#, options: .regularExpression),
            "scripts/checks/features-yaml-entry-points.py declares TOP_LEVEL_MENUS"
        )
        let known = Set(quotedStrings(in: String(script[declaration])))
        try withMainMenu { bar in
            XCTAssertEqual(known, Set(bar.items.dropFirst().map(\.title)), "the menus after the application menu")
        }
    }

    // MARK: - What counts as a menu path

    func testThePathsOfTheApplicationMenuAreNotMenuPaths() {
        for identity in [LungfishAppIdentity.debug, .preview, .stable] {
            let bar = MainMenu.createMainMenu(appIdentity: identity)
            XCTAssertEqual(bar.items.first?.title, identity.shortName)
            XCTAssertFalse(
                MenuPathWalker.startsAtMenu(of: bar, [identity.shortName, "Settings…"]),
                "the application menu is skipped on the \(identity.releaseChannel.rawValue) channel"
            )
            XCTAssertTrue(MenuPathWalker.startsAtMenu(of: bar, ["Tools", "Mapping"]))
            XCTAssertTrue(MenuPathWalker.startsAtMenu(of: bar, ["Tools…", "Mapping"]), "an ellipsis never counts")
            XCTAssertFalse(MenuPathWalker.startsAtMenu(of: bar, ["Import Center", "Variants"]), "a window, not a menu")
            XCTAssertFalse(MenuPathWalker.startsAtMenu(of: bar, ["CLI: lungfish map"]))
        }
    }

    // MARK: - The resolver

    func testTheResolverWalksSubmenusIgnoresEllipsesAndStopsAtTheFirstLeaf() {
        let bar = makeBar()
        func missing(_ path: String) -> (segment: String, parents: [String], available: [String])? {
            guard case .missing(let segment, let parents, let available) = MenuPathWalker.resolve(MenuPathWalker.segments(of: path), in: bar) else {
                return nil
            }
            return (segment, parents, available)
        }

        XCTAssertNil(missing("Tools > Mapping > minimap2..."), "three dots read as an ellipsis")
        XCTAssertNil(missing("Tools > Mapping > minimap2…"))
        XCTAssertNil(missing("Tools > Mapping…"), "a path may end on a submenu, with or without its stray ellipsis")
        XCTAssertNil(missing("Tools"), "a path may end on a menu of the bar")
        XCTAssertNil(missing("Tools > Plugin Manager… > wastewater-surveillance"), "the walk stops at the first leaf")
        XCTAssertNil(missing("Tools > Plugin Manager > anything > at all"))

        let wrongMenu = missing("Tools > Search Online Databases > Search NCBI…")
        XCTAssertEqual(wrongMenu?.segment, "Search Online Databases")
        XCTAssertEqual(wrongMenu?.parents, ["Tools"])
        XCTAssertEqual(wrongMenu?.available, ["Mapping", "Plugin Manager…"])

        let wrongItem = missing("File > Search Online Databases > Search Genomes…")
        XCTAssertEqual(wrongItem?.segment, "Search Genomes…", "the segment is reported as the file writes it")
        XCTAssertEqual(wrongItem?.parents, ["File", "Search Online Databases"])
        XCTAssertEqual(wrongItem?.available, ["Search NCBI…"])

        XCTAssertEqual(missing("Tools > Mapping > Viral Recon")?.parents, ["Tools", "Mapping"], "a moved item is missing from its old submenu")
        XCTAssertEqual(missing("Nowhere > Mapping")?.parents, [])
        XCTAssertNotNil(missing("File > Secret"), "a hidden item is not in the menu")
        XCTAssertNotNil(missing("Tools > "), "a separator has no title to match")
    }

    func testTheResolverFindsWhereAMovedItemLivesNow() {
        let bar = makeBar()
        XCTAssertEqual(MenuPathWalker.locations(of: "Search NCBI", in: bar), ["File > Search Online Databases > Search NCBI…"])
        XCTAssertEqual(MenuPathWalker.locations(of: "Mapping…", in: bar), ["Tools > Mapping"])
        XCTAssertEqual(MenuPathWalker.locations(of: "Secret", in: bar), [], "a hidden item is not offered")
    }

    // MARK: - The reader

    func testTheReaderFollowsBlockListsAndIgnoresEveryOtherField() {
        let yaml = """
        # features.yaml, with a header comment that mentions entry_points: [a, b]
        version: 0
        features:
          one.thing:
            title: One thing
            entry_points:
              - "Tools > Mapping…"
              - 'Selection > Tree Node'
              - Plain > Scalar # a comment
              - "CLI: lungfish one"
            outputs:
              - one-result
            notes: >-
              - not an entry point
          two.thing:
            entry_points: ["Tools > Inline"]
            title: Two
          three.thing:
            entry_points:
              - "File > Export"
        """
        let (entries, problems) = FeaturesYAMLEntryPoints.read(yaml)
        XCTAssertEqual(entries, [
            FeaturesYAMLEntryPoints.Entry(featureID: "one.thing", path: "Tools > Mapping…"),
            FeaturesYAMLEntryPoints.Entry(featureID: "one.thing", path: "Selection > Tree Node"),
            FeaturesYAMLEntryPoints.Entry(featureID: "one.thing", path: "Plain > Scalar"),
            FeaturesYAMLEntryPoints.Entry(featureID: "one.thing", path: "CLI: lungfish one"),
            FeaturesYAMLEntryPoints.Entry(featureID: "three.thing", path: "File > Export"),
        ])
        XCTAssertEqual(problems.count, 1, "an inline list is reported, never skipped")
        XCTAssertNotNil(problems.first?.range(of: "two.thing"), "the problem names its feature, \(problems)")
    }

    // MARK: - Fixtures

    /// The real menu bar over a throwaway defaults suite, with every catalog workflow
    /// enabled and no package linked, the way ToolsMenuStructureTests builds it. The
    /// application menu is the stable channel's, so its title never varies with the build.
    private func withMainMenu<Result>(_ body: (NSMenu) throws -> Result) throws -> Result {
        _ = NSApplication.shared
        let suiteName = "FeaturesYAMLMenuPath-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        for item in WorkflowLibraryCatalog.builtIn {
            enablementStore.setWorkflow(item, enabled: true)
        }
        return try body(
            MainMenu.createMainMenu(
                workflowLibraryEnablementStore: enablementStore,
                workflowPackageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults),
                appIdentity: .stable
            )
        )
    }

    /// A small bar for the resolver rules alone.
    private func makeBar() -> NSMenu {
        func item(_ title: String, _ children: [NSMenuItem]? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let children {
                let submenu = NSMenu(title: title)
                for child in children { submenu.addItem(child) }
                item.submenu = submenu
            }
            return item
        }
        let secret = item("Secret")
        secret.isHidden = true
        let bar = NSMenu()
        for top in [
            item("Lungfish", [item("Settings…")]),
            item("Tools", [
                item("Mapping", [item("minimap2…")]),
                NSMenuItem.separator(),
                item("Plugin Manager…"),
            ]),
            item("File", [
                item("Search Online Databases", [item("Search NCBI…")]),
                secret,
            ]),
        ] {
            bar.addItem(top)
        }
        return bar
    }

    private func readRepositoryFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readRepositorySource(root.appendingPathComponent(relativePath))
    }

    private func quotedStrings(in text: String) -> [String] {
        var strings: [String] = []
        var current: String?
        for character in text {
            if character == "\"" {
                if let finished = current {
                    strings.append(finished)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return strings
    }
}

// MARK: - features.yaml reader

/// Reads the `entry_points` strings of features.yaml. The file writes them as block lists of
/// strings under a feature id, one indentation level apart, so a line reader is enough and
/// the package needs no YAML dependency. A block this reader cannot follow is reported as a
/// problem and never skipped.
private enum FeaturesYAMLEntryPoints {
    struct Entry: Equatable {
        let featureID: String
        let path: String
    }

    static func read(_ yaml: String) -> (entries: [Entry], problems: [String]) {
        var entries: [Entry] = []
        var problems: [String] = []
        var featureID: String?
        var inEntryPoints = false
        for (index, rawLine) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }
            let isListItem = content.hasPrefix("- ")
            if indent == 2, !isListItem, content.hasSuffix(":") {
                featureID = String(content.dropLast())
                inEntryPoints = false
            } else if indent == 4, !isListItem {
                inEntryPoints = content == "entry_points:"
                if !inEntryPoints, content.hasPrefix("entry_points:") {
                    problems.append("line \(index + 1), \(featureID ?? "?"): entry_points is not a block list")
                }
            } else if inEntryPoints, isListItem, indent >= 4 {
                guard let featureID else {
                    problems.append("line \(index + 1): an entry point before any feature id")
                    continue
                }
                guard let path = scalar(String(content.dropFirst(2))) else {
                    problems.append("line \(index + 1), \(featureID): cannot read \(content)")
                    continue
                }
                entries.append(Entry(featureID: featureID, path: path))
            }
        }
        return (entries, problems)
    }

    /// The text of a double quoted, single quoted or plain YAML scalar.
    private static func scalar(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if first == "\"" {
            var value = ""
            var escaped = false
            for character in trimmed.dropFirst() {
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return value
                } else {
                    value.append(character)
                }
            }
            return nil
        }
        if first == "'" {
            guard let end = trimmed.dropFirst().lastIndex(of: "'") else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]).replacingOccurrences(of: "''", with: "'")
        }
        let plain = trimmed.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : plain
    }
}

// MARK: - Menu path resolution

/// Resolves a path of titles against a built menu bar.
@MainActor
private enum MenuPathWalker {
    enum Outcome {
        case resolved
        /// `segment` is not an item of the menu the walk had reached. `parents` are the
        /// titles walked so far, and `available` are the titles that menu holds.
        case missing(segment: String, parents: [String], available: [String])
    }

    /// The titles of a path, split at ">" and trimmed.
    nonisolated static func segments(of path: String) -> [String] {
        path.split(separator: ">", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A title as it is compared. A trailing ellipsis, a single character or three dots, is dropped.
    nonisolated static func normalizedTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("\u{2026}") {
            text.removeLast()
        } else if text.hasSuffix("...") {
            text.removeLast(3)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the path starts with a menu of the bar after the application menu. The
    /// application menu is named for the release channel, so a path that starts with the
    /// application's name is not checked.
    static func startsAtMenu(of bar: NSMenu, _ segments: [String]) -> Bool {
        guard let first = segments.first else { return false }
        let wanted = normalizedTitle(first)
        return bar.items.dropFirst().contains { normalizedTitle($0.title) == wanted }
    }

    /// Walks `segments` from the bar. An item that has no submenu ends the walk with a
    /// success, because the segments after it name things inside the window it opens.
    static func resolve(_ segments: [String], in bar: NSMenu) -> Outcome {
        var menu = bar
        var walked: [String] = []
        for (index, segment) in segments.enumerated() {
            let wanted = normalizedTitle(segment)
            let shown = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
            let matches = shown.filter { normalizedTitle($0.title) == wanted }
            guard let match = matches.first else {
                return .missing(segment: segment, parents: walked, available: shown.map(\.title))
            }
            walked.append(match.title)
            if index == segments.count - 1 { return .resolved }
            guard let submenu = matches.lazy.compactMap(\.submenu).first else { return .resolved }
            menu = submenu
        }
        return .resolved
    }

    /// Every place the bar holds an item with this title, as a path.
    static func locations(of title: String, in menu: NSMenu, under parents: [String] = []) -> [String] {
        let wanted = normalizedTitle(title)
        var found: [String] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            let path = parents + [item.title]
            if normalizedTitle(item.title) == wanted {
                found.append(path.joined(separator: " > "))
            }
            if let submenu = item.submenu {
                found += locations(of: title, in: submenu, under: path)
            }
        }
        return found
    }
}
