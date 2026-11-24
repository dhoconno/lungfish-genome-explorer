// GenotypeResultDisplaySectionViewModel+ResetView.swift - Reset View returns the genotype count filters to their defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension GenotypeResultDisplaySectionViewModel {
    /// View > Reset View (VS U3): the count filters, which the viewer does not keep, return to their defaults through
    /// the setters a person's change takes: the low-support switch and its percent, the minimum reads, and the matrix
    /// minimums and prevalence (VS-GENO BIO ruling 6).
    public func resetCountFilters() {
        let start = GenotypeResultDisplayState()
        setHideLowSupport(start.hideLowSupport)
        setMinimumSupportPercent(start.minimumSupportPercent)
        setMinimumReads(start.minimumReads)
        setMatrixMinimumReads(start.matrixMinimumReads)
        setMatrixMinimumPercent(start.matrixMinimumPercent)
        setMatrixMinimumPrevalencePercent(start.matrixMinimumPrevalencePercent)
    }

    /// Whether a count filter ``resetCountFilters()`` returns differs from its default, which enables View > Reset View
    /// while only a minimum is set (VS-INSP BIO SF-2, SWIFT SF-2).
    public var countFiltersDifferFromDefaults: Bool {
        let start = GenotypeResultDisplayState(), now = displayState
        return now.hideLowSupport != start.hideLowSupport || now.minimumSupportPercent != start.minimumSupportPercent
            || now.minimumReads != start.minimumReads || now.matrixMinimumReads != start.matrixMinimumReads
            || now.matrixMinimumPercent != start.matrixMinimumPercent
            || now.matrixMinimumPrevalencePercent != start.matrixMinimumPrevalencePercent
    }
}
