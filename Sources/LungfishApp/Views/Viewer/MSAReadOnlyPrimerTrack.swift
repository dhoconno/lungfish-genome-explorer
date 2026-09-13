import Foundation

/// A display overlay only: never included in alignment rows or consensus statistics.
struct MSAReadOnlyPrimerTrack: Equatable, Sendable {
    let id: String
    let label: String
    let alignedBases: [Int: Character]
    var showIdentityDots = true

    private static let allowed: [Character: Set<Character>] = [
        "A":["A"], "C":["C"], "G":["G"], "T":["T"], "R":["A","G"], "Y":["C","T"],
        "S":["G","C"], "W":["A","T"], "K":["G","T"], "M":["A","C"], "B":["C","G","T"],
        "D":["A","G","T"], "H":["A","C","T"], "V":["A","C","G"], "N":["A","C","G","T"]]

    static func make(id: String, name: String, sequence: String, strand: String, columns: [Int], showIdentityDots: Bool = true) throws -> Self {
        let bases = Array(sequence.uppercased())
        guard !bases.isEmpty, bases.count == columns.count, columns.allSatisfy({ $0 >= 0 }),
              columns == columns.sorted(), Set(columns).count == columns.count,
              bases.allSatisfy({ allowed[$0] != nil }), ["+", "-"].contains(strand) else {
            throw NSError(domain: "MSAReadOnlyPrimerTrack", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Primer sequence length and mapped reference columns do not agree."])
        }
        let complement: [Character: Character] = ["A":"T","C":"G","G":"C","T":"A","R":"Y","Y":"R","S":"S","W":"W","K":"M","M":"K","B":"V","V":"B","D":"H","H":"D","N":"N"]
        let displayed = strand == "-" ? bases.reversed().map { complement[$0]! } : bases
        return .init(id: id, label: "Primer · " + name + (strand == "-" ? " · ← reverse complement on reference axis" : " · → 5′–3′"),
            alignedBases: Dictionary(uniqueKeysWithValues: zip(columns, displayed)), showIdentityDots: showIdentityDots)
    }

    func displayedResidue(_ residue: Character, column: Int) -> Character {
        let uppercased = String(residue).uppercased()
        guard uppercased.count == 1, let canonical = uppercased.first else { return residue }
        guard showIdentityDots, "ACGT".contains(canonical), let primer = alignedBases[column],
              Self.allowed[primer]?.contains(canonical) == true else { return residue }
        return "."
    }

    func isDefiniteMismatch(_ residue: Character, column: Int) -> Bool {
        let uppercased = String(residue).uppercased()
        guard uppercased.count == 1, let canonical = uppercased.first else { return false }
        guard "ACGT".contains(canonical), let primer = alignedBases[column] else { return false }
        return Self.allowed[primer]?.contains(canonical) == false
    }
}
