// NaoMgsBamMaterializer+Orientation.swift - The strand a NAO-MGS mate is stored on in the BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

extension NaoMgsBamMaterializer {
    /// SAM stores a 0x10 record on the reference strand, SEQ reverse-complemented and QUAL reversed. NAO-MGS
    /// `query_seq` and `query_seq_rev` hold each mate as sequenced, and `prim_align_query_rc` names its strand.
    /// The helper sits in this file because `NaoMgsBamMaterializer.swift` is at the 800-line limit.
    static func referenceOriented(sequence: String, quality: String, reverse: Bool) -> (sequence: String, quality: String) {
        guard reverse else { return (sequence, quality) }
        let bases = String(sequence.reversed().map { complementOfBase[$0] ?? "N" })
        return (bases, quality == "*" ? quality : String(quality.reversed()))
    }

    /// The IUPAC complements in both cases. Any other character reads as `N`.
    private static let complementOfBase: [Character: Character] = [
        "A": "T", "T": "A", "C": "G", "G": "C", "N": "N", "R": "Y", "Y": "R", "K": "M", "M": "K",
        "B": "V", "V": "B", "D": "H", "H": "D", "S": "S", "W": "W",
        "a": "t", "t": "a", "c": "g", "g": "c", "n": "n", "r": "y", "y": "r", "k": "m", "m": "k",
        "b": "v", "v": "b", "d": "h", "h": "d", "s": "s", "w": "w",
    ]
}
