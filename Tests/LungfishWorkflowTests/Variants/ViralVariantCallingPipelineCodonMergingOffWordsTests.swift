// ViralVariantCallingPipelineCodonMergingOffWordsTests.swift - The words of the note that says iVar's codon merging was off
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-3 (BIO and UX review of ANNOT-EXPORT, SF-3). The note put the effect before the cause and ended on a
// remedy that cannot recreate a missing file, so the person was not told to make the calls again. It now gives the
// cause, then the effect, then the remedy, and says to call variants again.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ViralVariantCallingPipelineCodonMergingOffWordsTests: XCTestCase {
    func testTheNoteGivesTheCauseBeforeTheEffectAndTellsThePersonToCallVariantsAgain() {
        let note = ViralVariantCallingPipeline.codonMergingOffNote(AnnotationDatabase.LeftOutTrack(id: "track-g", name: "Genes"))

        XCTAssertEqual(
            note,
            "Codon merging was off for this run, because the annotation database of Genes, the bundle's first annotation "
                + "track, is missing or cannot be read. So its calls carry no codon or amino-acid change. "
                + "Reopen the bundle, and if this repeats, import those annotations again. Then call variants again."
        )
    }
}
