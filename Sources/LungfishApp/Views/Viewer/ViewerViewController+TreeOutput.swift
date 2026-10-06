// ViewerViewController+TreeOutput.swift - Where and under what name tree results are saved
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension ViewerViewController {
    /// The bundle URL for a tree result made in the app: the project's
    /// Analyses/Phylogenetic Trees folder plus a bounded, unique name.
    /// The folder is not created here.
    static func treeOutputURL(projectURL: URL, suggestedName: String) -> URL {
        nextAvailableBundleURL(
            suggestedName: suggestedName,
            pathExtension: "lungfishtree",
            in: PhylogeneticTreeOutputLocation.defaultDirectory(projectURL: projectURL)
        )
    }
}

extension TreeBundleTransformCommand {
    /// Names an extracted clade from its tip labels rather than the internal node's display
    /// label (which for an unlabeled node is its support value, giving "100-subtree"). Up to
    /// `maxListedTips` tips are joined with "+" while the joined name stays within
    /// `maxJoinedBytes`. Larger clades list the first tip and a count. Each label is cut to
    /// `maxTipLabelBytes` so a long sequence description cannot overflow the filename limit.
    static let maxListedTips = 3
    static let maxTipLabelBytes = 60
    static let maxJoinedBytes = 100

    static func subtreeNameStem(tipLabels: [String], fallback: String) -> String {
        let tips = tipLabels
            .map { boundedTipLabel(sanitizedFileNameComponent($0)) }
            .filter { !$0.isEmpty }
        guard let first = tips.first else {
            let cleaned = boundedTipLabel(sanitizedFileNameComponent(fallback))
            return cleaned.isEmpty ? "clade" : cleaned
        }
        if tips.count <= maxListedTips {
            let joined = tips.joined(separator: "+")
            if joined.utf8.count <= maxJoinedBytes { return joined }
        }
        return "\(first)+\(tips.count - 1)-more"
    }

    private static func boundedTipLabel(_ label: String) -> String {
        guard !label.isEmpty else { return label }
        return FileNameBudget.boundedStem(
            label,
            pathExtension: "",
            reservedSuffixBytes: 0,
            maxComponentBytes: maxTipLabelBytes
        )
    }

    private static func sanitizedFileNameComponent(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                (character == "/" || character == ":") ? "_" : character
            }
            .reduce(into: "") { $0.append($1) }
    }
}
