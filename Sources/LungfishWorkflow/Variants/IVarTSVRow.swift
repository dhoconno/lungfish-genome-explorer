// IVarTSVRow.swift - Typed view of a single iVar TSV variant row.

import Foundation

public struct IVarTSVRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case snp
        case insertion(insertedBases: String)
        case deletion(deletedBases: String)
    }

    public let region: String
    public let pos: Int
    public let ref: String
    public let alt: String
    public let refDP: Int
    public let refRV: Int
    public let refQual: Int
    public let altDP: Int
    public let altRV: Int
    public let altQual: Int
    public let altFreq: Double
    public let totalDP: Int
    public let pval: Double
    public let pass: Bool
    public let gffFeature: String?
    public let refCodon: String?
    public let refAA: String?
    public let altCodon: String?
    public let altAA: String?
    public let posAA: Int?
    public let kind: Kind

    public static func parse(line: String, header: String) -> IVarTSVRow? {
        let columns = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count == values.count, columns.count >= 14 else { return nil }
        var dict = [String: String](minimumCapacity: columns.count)
        for (column, value) in zip(columns, values) {
            dict[column] = value
        }
        guard
            let region = dict["REGION"],
            let posStr = dict["POS"], let pos = Int(posStr),
            let ref = dict["REF"],
            let alt = dict["ALT"],
            let refDP = Int(dict["REF_DP"] ?? ""),
            let refRV = Int(dict["REF_RV"] ?? ""),
            let refQual = Int(dict["REF_QUAL"] ?? ""),
            let altDP = Int(dict["ALT_DP"] ?? ""),
            let altRV = Int(dict["ALT_RV"] ?? ""),
            let altQual = Int(dict["ALT_QUAL"] ?? ""),
            let altFreq = Double(dict["ALT_FREQ"] ?? ""),
            let totalDP = Int(dict["TOTAL_DP"] ?? ""),
            let pval = Double(dict["PVAL"] ?? "1.0"),
            let passStr = dict["PASS"]
        else {
            return nil
        }
        let pass = passStr.uppercased() == "TRUE"
        let kind: Kind
        if alt.hasPrefix("+") {
            kind = .insertion(insertedBases: String(alt.dropFirst()))
        } else if alt.hasPrefix("-") {
            kind = .deletion(deletedBases: String(alt.dropFirst()))
        } else {
            kind = .snp
        }
        func optionalString(_ key: String) -> String? {
            guard let raw = dict[key], !raw.isEmpty, raw != "NA" else { return nil }
            return raw
        }
        return IVarTSVRow(
            region: region,
            pos: pos,
            ref: ref,
            alt: alt,
            refDP: refDP,
            refRV: refRV,
            refQual: refQual,
            altDP: altDP,
            altRV: altRV,
            altQual: altQual,
            altFreq: altFreq,
            totalDP: totalDP,
            pval: pval,
            pass: pass,
            gffFeature: optionalString("GFF_FEATURE"),
            refCodon: optionalString("REF_CODON"),
            refAA: optionalString("REF_AA"),
            altCodon: optionalString("ALT_CODON"),
            altAA: optionalString("ALT_AA"),
            posAA: optionalString("POS_AA").flatMap(Int.init),
            kind: kind
        )
    }
}
