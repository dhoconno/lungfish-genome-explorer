// GenotypeCohortSmartFilter+Identity.swift - The identity of a smart cohort
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The identity of a smart cohort (Phase 2.8 decisions O2 and G2).
///
/// A cohort stores an optional `id`, a UUID. `lungfish-cli genotype
/// export-labkey` writes it as `cohort_id`, so deleting, dismissing, restoring
/// or renaming one cohort never renumbers another. A cohort that stores none
/// has one derived on read from its scope and name, and a read never writes it.
/// The next save of the sidecar stores the derived value before any rename
/// applies, so a renamed cohort keeps the id it had. An older sidecar has no
/// `id` key and reads as before, and an older reader ignores the key.
extension GenotypeCohortSmartFilter {
    /// The namespace of every cohort id derived from a scope and a name.
    ///
    /// It was generated once with `uuidgen`. It must never change. Every id
    /// derived under it is stored in sidecars and keys rows in LabKey lists, so
    /// a different namespace would give every cohort a new identity.
    static let derivationNamespace = UUID(uuidString: "EAE6B16C-E0F3-4099-B3D7-DB52CED9199C")!

    /// The id a cohort has before it stores one.
    ///
    /// It is a UUID version 5 (RFC 4122) under `derivationNamespace` over the
    /// UTF-8 bytes of the JSON array `[scope, name]`. The n-th cohort of one
    /// scope and name in a sidecar, counting in sidecar order, derives from
    /// `[scope, name, n]` when n is 2 or more, so the ids of one sidecar differ.
    /// The array is compact JSON with the minimal escapes of RFC 8259, so Python's
    /// `json.dumps([scope, name], separators=(",", ":"), ensure_ascii=False)`
    /// gives the same bytes, and `uuid.uuid5` over them gives the same id.
    /// `genotype export-labkey` writes the id in lower case, as Python prints
    /// it. The sidecar JSON holds Foundation's upper case text, and a UUID
    /// parses from either.
    ///
    /// - Parameter ordinal: The place of the cohort among those with its scope
    ///   and name, starting at 1.
    public static func derivedID(scope: String, name: String, ordinal: Int = 1) -> UUID {
        UUID(versionFiveNamespace: derivationNamespace, name: derivationInput(scope: scope, name: name, ordinal: ordinal))
    }

    /// The bytes `derivedID` hashes.
    static func derivationInput(scope: String, name: String, ordinal: Int) -> Data {
        var array = "[" + jsonString(scope) + "," + jsonString(name)
        if ordinal >= 2 {
            array += ",\(ordinal)"
        }
        return Data((array + "]").utf8)
    }

    /// A JSON string literal that escapes the quote, the backslash and the
    /// control characters, and nothing else. A slash and a character outside
    /// ASCII stay as they are.
    private static func jsonString(_ text: String) -> String {
        var literal = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": literal += "\\\""
            case "\\": literal += "\\\\"
            case "\u{08}": literal += "\\b"
            case "\u{0C}": literal += "\\f"
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    literal += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    literal.unicodeScalars.append(scalar)
                }
            }
        }
        return literal + "\""
    }

    /// The id of each cohort of `cohorts`, in order. A cohort that stores an id
    /// has it, and any other has the derived id of its scope, name and place
    /// among the cohorts of that scope and name. Stored ids are never changed.
    /// A derived id that equals a stored id, or one derived before it, moves to
    /// the next place, so the ids of the array stay distinct whenever its
    /// stored ids are.
    public static func resolvedIDs(of cohorts: [GenotypeCohortSmartFilter]) -> [UUID] {
        var taken = Set(cohorts.compactMap(\.id))
        var placeByGroup: [CohortGroup: Int] = [:]
        return cohorts.map { cohort in
            let group = CohortGroup(scope: cohort.scope, name: cohort.name)
            var ordinal = (placeByGroup[group] ?? 0) + 1
            placeByGroup[group] = ordinal
            if let stored = cohort.id { return stored }
            var candidate = derivedID(scope: cohort.scope, name: cohort.name, ordinal: ordinal)
            while !taken.insert(candidate).inserted {
                ordinal += 1
                candidate = derivedID(scope: cohort.scope, name: cohort.name, ordinal: ordinal)
            }
            return candidate
        }
    }

    /// This cohort where it replaces `replaced`. It keeps its own id, and a
    /// cohort that stores none takes the id of the cohort it replaces, so
    /// saving a cohort again under its name does not make a new cohort.
    public func inheritingID(from replaced: GenotypeCohortSmartFilter?) -> GenotypeCohortSmartFilter {
        var copy = self
        copy.id = id ?? replaced?.id
        return copy
    }
}

private struct CohortGroup: Hashable {
    let scope: String
    let name: String
}

extension GenotypeAnnotationSidecar {
    /// The id of each smart cohort, in order. Reading it changes nothing.
    public var resolvedSmartCohortIDs: [UUID] {
        GenotypeCohortSmartFilter.resolvedIDs(of: smartCohorts)
    }

    /// Stores the derived id of every smart cohort that stores none. A save
    /// calls it before any edit of the cohorts applies, so a cohort that is
    /// renamed afterwards keeps its id. Calling it again changes nothing.
    public mutating func storeSmartCohortIDs() {
        let ids = resolvedSmartCohortIDs
        for index in smartCohorts.indices where smartCohorts[index].id == nil {
            smartCohorts[index].id = ids[index]
        }
    }

    /// This sidecar with `storeSmartCohortIDs()` applied.
    public func storingSmartCohortIDs() -> GenotypeAnnotationSidecar {
        var stored = self
        stored.storeSmartCohortIDs()
        return stored
    }
}

private extension UUID {
    /// The name-based UUID of RFC 4122 section 4.3 with version 5, which hashes
    /// the namespace bytes and the name with SHA-1. The definition of version 5
    /// asks for SHA-1, and here it names a cohort and protects nothing.
    init(versionFiveNamespace namespace: UUID, name: Data) {
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(name)
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
