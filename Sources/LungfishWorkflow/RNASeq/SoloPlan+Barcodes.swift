// SoloPlan+Barcodes.swift - The two known 10x barcode lists and the choice of a plan's list (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// One known whole list, by the SHA-256 and size measured on lge_scratch (BIO-SOLO-GTF Q3), which equal the pins of
/// `scripts/repro/rnaseq/tenx-controls/README.md:36-37`.
package struct SoloBarcodeList: Sendable, Equatable {
    package var name: String
    package var sha256: String
    package var size: Int64
    /// The number of barcodes, one a line, as a person reads it.
    package var barcodes: String
    package var chemistry: String

    /// `barcodes/<name>.txt`, where the plan's `barcodeList` entry sits and STAR's `--soloCBwhitelist` reads it.
    package var relativePath: String { "barcodes/\(name).txt" }

    var words: String { "\(name) (SHA-256 \(sha256), \(barcodes) barcodes) for \(chemistry)" }
}

/// The list a plan pins, the source the executor takes it from, and the words the record states (BIO-SOLO-GTF item 9).
package struct SoloBarcodeChoice: Sendable, Equatable {
    package var list: SoloBarcodeList
    package var source: PlanBarcodeListSource
    package var words: String

    package var entry: PlanEntry {
        PlanEntry(role: .barcodeList, relativePath: list.relativePath, sha256: list.sha256, size: list.size,
                  barcodeList: PlanBarcodeListIdentity(name: list.name, source: source))
    }
}

/// The table of the known lists. 3' v3 takes 3M and 5' v2 takes 737K, and 77,142 barcodes are in both (BIO-SOLO-GTF item
/// 8), so a library counted on the other chemistry's list keeps a share of its cells with no error and is refused.
package enum SoloPlanBarcodes {
    package static let threePrimeV3 = SoloBarcodeList(
        name: "3M-february-2018", sha256: "843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b",
        size: 115_512_960, barcodes: "6,794,880", chemistry: "10x 3' v3")
    package static let fivePrimeV2 = SoloBarcodeList(
        name: "737K-august-2016", sha256: "b0dda4b114d8fc7ea8def94fb472e6205c1831a72e3ac245ed13cc332d9f20d1",
        size: 12_533_760, barcodes: "737,280", chemistry: "10x 5' v2")
    package static let known = [threePrimeV3, fivePrimeV2]

    package static let fromImage = "list in the tool image"
    package static let supplied = "list supplied by the user"
    package static let suppliedEqualToImage = "list supplied by the user, equal by SHA-256 to the list in the tool image"

    /// The preset's list. With no list given it is the image's, which the pinned tool manifest must list by SHA-256 under
    /// `files` with role `barcodeList`. A given list must be the preset's whole list by SHA-256 and size. Its source is
    /// `image` when the manifest holds the same bytes, which the executor then copies, and `supplied` otherwise.
    package static func choose(
        preset: SoloPlanPreset, supplied given: ExecutorPlanSourceFile?, imageFiles: [ImageDataFile]
    ) throws -> SoloBarcodeChoice {
        let own = preset.barcodeList
        let inImage = imageFiles.contains { $0.role == "barcodeList" && $0.sha256 == own.sha256 && $0.size == own.size }
        guard let given else {
            guard inImage else {
                throw SoloPlanError("The tool image holds no barcode list \(own.words), which the preset \(preset.name) "
                    + "reads, and LGE takes a list from nowhere else. Give that whole list with --barcode-list, which LGE checks "
                    + "by SHA-256 and never copies.")
            }
            return SoloBarcodeChoice(list: own, source: .image, words: fromImage)
        }
        if let other = known.first(where: { $0.sha256 == given.sha256 && $0.name != own.name }) {
            throw SoloPlanError("The preset \(preset.name) reads the barcode list \(own.words), and the list you gave is "
                + "\(other.words). A library counted on another chemistry's list keeps only the cells whose barcodes are in "
                + "both lists, with no error, so give the list \(own.name).")
        }
        guard given.sha256 == own.sha256, given.size == own.size else {
            throw SoloPlanError("The barcode list \(given.url.lastPathComponent) has SHA-256 \(given.sha256) and \(given.size) "
                + "bytes, which is neither known list: \(threePrimeV3.words), or \(fivePrimeV2.words). LGE takes a whole known "
                + "list by SHA-256, never a cut or edited one, so give the whole list \(own.name) for the preset \(preset.name).")
        }
        return SoloBarcodeChoice(list: own, source: inImage ? .image : .supplied, words: inImage ? suppliedEqualToImage : supplied)
    }
}
