// GenotypeResultSelectionState.swift - Selection state for genotype result inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import LungfishIO

public struct GenotypeResultSelectionState: Equatable {
    public let title: String
    public let subtitle: String?
    public let detailRows: [(String, String)]
    public let highlightTarget: GenotypeResultHighlightTarget?
    public let highlightColor: AnnotationColor?
    public let highlightStyle: GenotypeResultHighlightStyle
    public let matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    /// Animal/sample id when the selection represents a sample row (vs a
    /// shared allele label). The "Edit calls…" button dispatches to this
    /// id so the Sample Detail sheet opens for the right sample. nil
    /// when the selection is something else (allele, locus, etc.).
    public let animalId: String?

    public init(
        title: String,
        subtitle: String?,
        detailRows: [(String, String)],
        highlightTarget: GenotypeResultHighlightTarget? = nil,
        highlightColor: AnnotationColor? = nil,
        highlightStyle: GenotypeResultHighlightStyle = .default,
        matrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] = [],
        animalId: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detailRows = detailRows
        self.highlightTarget = highlightTarget
        let resolvedStyle = highlightStyle.isDefault && highlightColor != nil
            ? GenotypeResultHighlightStyle(fillColor: highlightColor)
            : highlightStyle
        self.highlightColor = resolvedStyle.fillColor
        self.highlightStyle = resolvedStyle
        self.matrixTargets = matrixTargets
        self.animalId = animalId
    }

    public static func == (
        lhs: GenotypeResultSelectionState,
        rhs: GenotypeResultSelectionState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.detailRows.elementsEqual(rhs.detailRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.highlightTarget == rhs.highlightTarget &&
            lhs.highlightColor == rhs.highlightColor &&
            lhs.highlightStyle == rhs.highlightStyle &&
            lhs.matrixTargets == rhs.matrixTargets &&
            lhs.animalId == rhs.animalId
    }
}
