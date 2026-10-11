// FASTQOperationToolID+Tokens.swift - The analysis kind behind a classify tool and the stem it names its output with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension FASTQOperationToolID {
    /// The analysis kind a classify run records, or nil for a tool that is not a classifier.
    ///
    /// This is the one mapping from a dialog tool to its `AnalysisToolID`. What a classifier hands on
    /// to the rest of the app, such as its output stem, is read from the descriptor of
    /// this id and is not spelled again from the dialog title.
    var classifierAnalysisToolID: AnalysisToolID? {
        switch self {
        case .kraken2: return .kraken2
        case .esViritu: return .esviritu
        case .taxTriage: return .taxtriage
        default: return nil
        }
    }

    /// The stem of the name a classify run gives its output, read from the classifier's descriptor.
    ///
    /// No run reads this stem yet. Classify folders are named with the analysis id by
    /// `AnalysesFolder.createAnalysisDirectory(tool:)`, and that id equals this stem for all three
    /// classifiers. A tool without a descriptor stem keeps the lowercased title it had before the
    /// stem moved onto the descriptor.
    var classifyOutputStem: String {
        classifierAnalysisToolID.flatMap { AnalysisToolRegistry.descriptor(for: $0)?.outputStem }
            ?? title.lowercased()
    }
}
