// AssemblySubsetBundleMetadata.swift - Metadata for derived contig subset bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public enum AssemblySubsetBundleMetadata {
    public static func makeGroups(
        assembler: String,
        sourceAssemblyName: String,
        selectedContigs: [String],
        selectionSummary: AssemblyContigSelectionSummary
    ) -> [MetadataGroup] {
        [
            MetadataGroup(
                name: "Derived Subset",
                items: [
                    MetadataItem(label: "Assembler", value: assembler),
                    MetadataItem(label: "Source Assembly", value: sourceAssemblyName),
                    MetadataItem(label: "Selected Contigs", value: selectedContigs.joined(separator: ", ")),
                    MetadataItem(label: "Contigs", value: "\(selectionSummary.selectedContigCount)"),
                    MetadataItem(label: "Total Length", value: "\(selectionSummary.totalSelectedBP.formatted()) bp"),
                    MetadataItem(
                        label: "GC Content",
                        value: String(format: "%.1f%%", selectionSummary.lengthWeightedGCPercent)
                    ),
                ]
            ),
        ]
    }
}
