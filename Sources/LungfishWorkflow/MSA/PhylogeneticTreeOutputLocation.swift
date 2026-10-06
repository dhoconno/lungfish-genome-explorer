// PhylogeneticTreeOutputLocation.swift - Where tree results made in the app are saved
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Where tree inference, re-root and extract-subtree results are written.
/// They live under Analyses with the other tool results. Imported trees stay
/// in the project root `Phylogenetic Trees` folder.
public enum PhylogeneticTreeOutputLocation {
    /// The grouping folder name inside Analyses.
    public static let folderName = "Phylogenetic Trees"

    /// `<project>/Analyses/Phylogenetic Trees`.
    public static func defaultDirectory(projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }
}
