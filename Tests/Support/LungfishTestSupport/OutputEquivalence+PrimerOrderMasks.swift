// OutputEquivalence+PrimerOrderMasks.swift - The capture time, digest and own-root masks of the primer exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalence+Masks.swift is over the size baseline and may not grow, so the masks of the primer order and
// primer selection exports live here, in an extension of the same enum. Each is one reviewed row of the Masks and Same
// result table of docs/contracts/CLI-EQUIVALENCE.md (ruling 1 of the 13.43-M3 review, manager decision MD81), and
// RouteParityHarnessTests holds a negative control for each. M-3, the order workbook compared through its parts, is
// the `primer-order.xlsx` rule of `normalizedPayload` in OutputEquivalence+Normalize.swift.

import Foundation

extension OutputEquivalence.Masks {
    /// M-1 and M-2. The run clock of a primer order, each timestamp set to `<TIMESTAMP>` where the text is one of two
    /// documents.
    ///
    /// - An order document (`order.json`): `selection.capturedAt`, the time the export captured the selection
    ///   (`PrimerOrderExportService.captureSelection` stamps `Date()`, so a run against its own replay differs in it).
    ///   The object holds the keys `selection`, `oligos` and `metadata`, and `selection` holds `capturedAt`.
    /// - A part of the order workbook (a worksheet or the shared strings of `workbook-parts/`): the ISO 8601 value
    ///   that follows the `Captured at` text, which the workbook writes to the second. The value alone is replaced,
    ///   never the part.
    ///
    /// The same key in any other document, any other value of the two documents and every other date are compared as
    /// written.
    public static let primerOrderCaptureClocks = OutputEquivalence.Mask(name: "primerOrderCaptureClocks") { text, _ in
        let order = rewritingJSON(text) { value, changed in maskOrderCapturedAt(in: value, changed: &changed) }
        return maskCapturedAtCell(in: order)
    }

    /// M-4. The checksum and size a record states for the files that are compared by their content, each set to a
    /// placeholder. These are `order.json`, `primer-order.xlsx` and every part under `workbook-parts/`. Their bytes
    /// follow the clock of M-1 to M-3 and the files are compared on their masked text or their parts. An entry for any
    /// other file keeps its digest and size.
    public static let primerOrderRecordDigests = OutputEquivalence.Mask(name: "primerOrderRecordDigests") { text, _ in
        rewritingJSON(text) { value, changed in maskOrderRecordDigests(in: value, changed: &changed) }
    }

    /// M-5. A bundle manifest's `source.source_url`, the folder a copy was made from, becomes `<workspace>/` and the
    /// folder's own name. The value names the side's own root, which is right and differs by side. A parity class still
    /// fails a side that names another side's root, which `RouteParityHarness` checks on the unmasked tree.
    public static let primerExportSourceURL = OutputEquivalence.Mask(name: "primerExportSourceURL") { text, _ in
        rewritingJSON(text) { value, changed in maskSourceURL(in: value, changed: &changed) }
    }

    static func maskOrderCapturedAt(in value: Any, changed: inout Bool) -> Any {
        guard var document = value as? [String: Any],
              Set(document.keys).isSuperset(of: ["selection", "oligos", "metadata"]),
              var selection = document["selection"] as? [String: Any],
              selection["capturedAt"] != nil
        else { return value }
        selection["capturedAt"] = "<TIMESTAMP>"
        document["selection"] = selection
        changed = true
        return document
    }

    static func maskCapturedAtCell(in text: String) -> String {
        guard text.contains("Captured at"), text.contains("<worksheet") || text.contains("<sst") else { return text }
        let pattern = #"(Captured at[\s\S]{0,400}?)\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})"#
        return text.replacingOccurrences(of: pattern, with: "$1<TIMESTAMP>", options: .regularExpression)
    }

    static func isOrderCompared(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "order.json" || name == "primer-order.xlsx" || path.contains("workbook-parts/")
    }

    static func maskOrderRecordDigests(in value: Any, changed: inout Bool) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object {
                object[key] = maskOrderRecordDigests(in: child, changed: &changed)
            }
            let names = object.values.compactMap { $0 as? String }
            if names.contains(where: isOrderCompared) {
                for key in object.keys where digestKeys.contains(key) {
                    object[key] = "<CONTENT-SHA256>"
                    changed = true
                }
                for key in object.keys where sizeKeys.contains(key) {
                    object[key] = "<CONTENT-SIZE>"
                    changed = true
                }
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map { maskOrderRecordDigests(in: $0, changed: &changed) }
        }
        return value
    }

    static func maskSourceURL(in value: Any, changed: inout Bool) -> Any {
        guard var manifest = value as? [String: Any],
              var source = manifest["source"] as? [String: Any],
              let url = source["source_url"] as? String
        else { return value }
        let name = url.split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? ""
        source["source_url"] = "<workspace>/" + name
        manifest["source"] = source
        changed = true
        return manifest
    }
}
