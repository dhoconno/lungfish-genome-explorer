// BarcodeKitRegistry+DefinitionLayout.swift - The kit line and the quoted fields of a custom barcode definition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN (D1b, L8). The Demux tab's table reaches the run as a custom definition, so a definition
// must keep every name a person typed (a quoted field) and the platform and search of the kit the plan was made on
// (a `# kit:` line). The layout is in `docs/formats/barcode-definition.md`.

import Foundation

extension BarcodeKitRegistry {

    /// Loads a custom barcode kit from the bytes of a definition, so a caller that keeps a copy of the definition it
    /// ran keeps the bytes it read. The bytes must be UTF-8 text.
    public static func loadCustomKit(data: Data, name: String) throws -> BarcodeKitDefinition {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return try loadCustomKit(text: text, name: name)
    }

    /// Loads a custom barcode kit from the text of a definition.
    ///
    /// A `# kit: <id>` line names the built-in kit the definition was made on. The kit then keeps that kit's vendor,
    /// platform, kit type, indexing and pairing with the definition's rows, so its run searches the reads as a run
    /// of the kit itself does and never falls back to the bare search of a custom kit. `sourceKitID` names the kit,
    /// whose barcodes the route owner counts in the read names (ruling ARCH-DEMUX-PLAN-CONTROL C1). A kit this
    /// version does not know, two kit lines that name different kits, and rows whose index count differs from the
    /// kit's refuse. Without the line the kit is a custom kit, single or dual indexed as its rows are.
    public static func loadCustomKit(text: String, name: String) throws -> BarcodeKitDefinition {
        let barcodes = try parseDelimitedBarcodeRecords(text)
        let sanitizedID = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let id = "custom-\(sanitizedID)"

        guard let kitID = try definitionKitID(in: text) else {
            let isDualIndexed = barcodes.contains { $0.i5Sequence != nil }
            return BarcodeKitDefinition(
                id: id,
                displayName: name,
                vendor: "custom",
                isDualIndexed: isDualIndexed,
                pairingMode: isDualIndexed ? .fixedDual : .singleEnd,
                barcodes: barcodes
            )
        }
        guard let kit = kit(byID: kitID) else {
            throw BarcodeKitLoadError.unknownKit(id: kitID)
        }
        let kitHasSecondary = kit.barcodes.contains { $0.i5Sequence != nil }
        if let row = barcodes.first(where: { ($0.i5Sequence != nil) != kitHasSecondary }) {
            throw BarcodeKitLoadError.kitIndexMismatch(kit: kit.displayName, id: row.id, kitHasSecondary: kitHasSecondary)
        }
        return BarcodeKitDefinition(
            id: id,
            displayName: name,
            vendor: kit.vendor,
            platform: kit.platform,
            kitType: kit.kitType,
            isDualIndexed: kit.isDualIndexed,
            pairingMode: kit.pairingMode,
            barcodes: barcodes,
            sourceKitID: kit.id
        )
    }

    /// The kit ID a definition's `# kit:` comment lines name, or nil when none does. The key is read in any case and
    /// the ID as written.
    static func definitionKitID(in content: String) throws -> String? {
        var found: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard body.lowercased().hasPrefix("kit:") else { continue }
            let kitID = body.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if let found, found != kitID {
                throw BarcodeKitLoadError.conflictingKitLines(first: found, second: kitID)
            }
            found = kitID
        }
        return found
    }

    /// Splits a definition line that holds a quote, as RFC 4180 reads a CSV record: a field that starts with `"` runs
    /// to the next lone `"`, `""` inside it is one quote, and a comma or tab inside it is text. The delimiter is the
    /// first comma or tab outside quotes, else runs of spaces. Unquoted fields are trimmed, quoted fields are kept as
    /// written between their quotes.
    static func splitQuotedDefinitionLine(_ line: String) -> [String] {
        var inQuotes = false
        var delimiter: Character = " "
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, character == "," || character == "\t" {
                delimiter = character
                break
            }
        }

        var fields: [String] = []
        var field = ""
        var quoted = false
        var inQuotedField = false
        var characters = Array(line)[...]
        func finishField() {
            fields.append(quoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            quoted = false
        }
        while let character = characters.popFirst() {
            if inQuotedField {
                if character == "\"" {
                    if characters.first == "\"" {
                        field.append("\"")
                        characters.removeFirst()
                    } else {
                        inQuotedField = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == delimiter {
                // Runs of spaces are one delimiter, as the unquoted whitespace split reads them.
                if delimiter == " ", field.isEmpty, !quoted { continue }
                finishField()
            } else if character == "\"", !quoted, field.allSatisfy(\.isWhitespace) {
                field = ""
                quoted = true
                inQuotedField = true
            } else if quoted, character.isWhitespace {
                continue
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || quoted || delimiter != " " {
            finishField()
        }
        return fields
    }
}
