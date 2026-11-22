// LungfishHelpContent+Placement.swift - The catalog checks a module runs on its own help items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a help item lives, and how its module checks it.
///
/// The items that already live in LungfishKit stay in ``LungfishHelpContent/allItems``. A leaf module builds the
/// ``LungfishHelpContent/HelpItem`` values its own views show, in its own module and from its own constants, so a ruled
/// string has one home and no module edits a shared list in Kit. That module's tests call
/// ``LungfishHelpContent/catalogFaults(in:)`` on those items and expect an empty result. Which words go in view, behind an
/// info button or in a help tag is the section Where words go of `docs/design/design-system/README.md`.
public extension LungfishHelpContent {
    /// One way a help item breaks the catalog rules.
    enum CatalogFaultKind: Equatable, Sendable {
        case emptyID
        case duplicateID
        case emptySummary
        /// A summary longer than ``LungfishHelpContent/summaryWordLimit`` words, with its count.
        case summaryTooLong(words: Int)
        /// A banned word or mark in the summary or the detail.
        case bannedWord(String)
        case emDash
    }

    /// A broken catalog rule and the id of the item that breaks it.
    struct CatalogFault: Equatable, Sendable, CustomStringConvertible {
        public let id: String
        public let kind: CatalogFaultKind

        public init(id: String, kind: CatalogFaultKind) {
            self.id = id
            self.kind = kind
        }

        public var description: String { "\(id): \(kind)" }
    }

    /// The most words a summary holds, since the summary is a help tag.
    nonisolated static let summaryWordLimit = 20

    /// Words and marks no help copy uses, matched without regard to case.
    nonisolated static let bannedWords = [
        "revolutionary",
        "breakthrough",
        "powerful",
        "cutting-edge",
        "AI-powered",
        "game-changing",
        "unleash",
        "leverages",
        "!",
    ]

    /// Each catalog fault of `items`, in item order: an empty id, an id used before in `items`, an empty summary, a
    /// summary over ``summaryWordLimit`` words, a word of ``bannedWords`` or an em dash in the summary or the detail.
    nonisolated static func catalogFaults(in items: [HelpItem]) -> [CatalogFault] {
        var faults: [CatalogFault] = []
        var seen: Set<String> = []
        for item in items {
            if item.id.isEmpty {
                faults.append(CatalogFault(id: item.id, kind: .emptyID))
            } else if !seen.insert(item.id).inserted {
                faults.append(CatalogFault(id: item.id, kind: .duplicateID))
            }
            if item.summary.isEmpty {
                faults.append(CatalogFault(id: item.id, kind: .emptySummary))
            }
            let words = item.summary.split { $0.isWhitespace || $0.isNewline }.count
            if words > summaryWordLimit {
                faults.append(CatalogFault(id: item.id, kind: .summaryTooLong(words: words)))
            }
            let copy = "\(item.summary) \(item.detail ?? "")"
            for word in bannedWords where copy.localizedCaseInsensitiveContains(word) {
                faults.append(CatalogFault(id: item.id, kind: .bannedWord(word)))
            }
            if copy.contains("\u{2014}") {
                faults.append(CatalogFault(id: item.id, kind: .emDash))
            }
        }
        return faults
    }
}
