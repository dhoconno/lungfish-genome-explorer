// TaxTriageSample+PipelineName.swift - The name the TaxTriage pipeline gives a sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageSample {

    /// The characters the pipeline's samplesheet check removes from a sample name.
    ///
    /// They are the list in `RowChecker._validate_sample` of `bin/check_samplesheet.py`, read at the revision the
    /// pin names (jhuapl-bio/taxtriage v3.3.8, commit e10bfebda32a62711f38a4e23ab03b61725a9675, in
    /// `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`). A bump of that pin must
    /// read the function again and keep ``TaxTriagePipelineNameTests`` true.
    private static let pipelineRemovedScalars: Set<Unicode.Scalar> = Set(
        "/\\:*?\"<>|()[]{}#%&+!@$^`~;,".unicodeScalars
    )

    /// The name the pipeline gives the sample that LGE holds as `name`, which its reports and so the result's
    /// database use for it.
    ///
    /// LGE keeps the name a person typed and writes it into the samplesheet as it is. The pipeline's samplesheet
    /// check then turns each space into an underscore, removes the characters in ``pipelineRemovedScalars`` and
    /// strips the whitespace that remains from both ends. The function works on unicode scalars, as the script
    /// works on code points. It does not add the `_T<n>` that the script appends when two samples of one
    /// samplesheet end with the same name. ``TaxTriageControlMatch`` reads that part.
    ///
    /// - Parameter name: The sample name as LGE holds it.
    /// - Returns: The name as the pipeline writes it. It can be empty when the name holds nothing else.
    public static func pipelineName(of name: String) -> String {
        var kept: [Unicode.Scalar] = []
        for scalar in name.unicodeScalars {
            if scalar == " " {
                kept.append("_")
            } else if !pipelineRemovedScalars.contains(scalar) {
                kept.append(scalar)
            }
        }
        while let last = kept.last, isPipelineWhitespace(last) {
            kept.removeLast()
        }
        let leading = kept.prefix { isPipelineWhitespace($0) }.count
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: kept.dropFirst(leading))
        return String(scalars)
    }

    /// Python's `str.strip()` removes the characters for which `str.isspace()` holds. They are the Unicode
    /// White_Space characters and the four information separators U+001C to U+001F.
    private static func isPipelineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}
