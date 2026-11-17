// AffectedResults+DemultiplexReadNames.swift - Whether an Exact Bare record searched for barcodes that sat in the read names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension AffectedResults {
    /// Whether a `lungfish fastq demultiplex` record is an Exact Bare Barcode run whose input's read names carry two or more
    /// of the kit's barcodes, a run that searched the read sequences for barcodes that sat in the names
    /// (DEMUX-EXACT-BARE-NO-FLOOR, BIO-DEMUX-THREE item 11). Every record of the engine names it as `engine: "exact-bare"`
    /// since its landing in 4389cd101, and the input and the kit beside it. Records since 9ad886777 also say
    /// `chanceCheck: "none"`.
    ///
    /// A record whose `optIn` is true is such a run by the person's choice, since preflight refuses it otherwise. Any other
    /// is read: the first read names of the input the record names (the primary FASTQ of a bundle), counted against the
    /// kit the record names by the route owner's rule (`DemultiplexSearchRouteOwner.presentBarcodes(of:inProbed:)`). The
    /// kit is the built-in kit of that id or the definition file the run keeps in its result folder. A record whose input
    /// or definition cannot be read is not such a run. It reads files, so the Inspector's lookup runs it off the main actor.
    static func searchedReadNameBarcodesWithExactBare(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        guard options["engine"] == .string(DemultiplexEngine.exactBareBarcode.rawValue) else { return false }
        if options["optIn"] == .boolean(true) { return true }
        let inputPath: String
        switch options["input"] {
        case .file(let url)?: inputPath = url.path
        case .string(let path)?: inputPath = path
        default: return false
        }
        guard case .string(let named)? = options["kit"] else { return false }
        let kit: BarcodeKitDefinition
        if let builtIn = BarcodeKitRegistry.kit(byID: named) {
            kit = builtIn
        } else {
            let url = URL(fileURLWithPath: named)
            guard let data = try? Data(contentsOf: url),
                  let loaded = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent)
            else { return false }
            kit = loaded
        }
        var input = URL(fileURLWithPath: inputPath)
        if FASTQBundle.isBundleURL(input) { input = FASTQBundle.resolvePrimaryFASTQURL(for: input) ?? input }
        guard FileManager.default.fileExists(atPath: input.path),
              let headers = try? FASTQReadLayoutClassifier.readHeaders(
                from: input, limit: DemultiplexSearchRouteOwner.readOnCount
              ).headers
        else { return false }
        // A header line holds the name and its comment as the FASTQ reader splits them, at the first space or tab.
        let names = headers.map { header -> FASTQReadNameIndex in
            let parts = header.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count > 1 else { return FASTQReadNameIndex(rawName: header) }
            return FASTQReadNameIndex(rawName: "\(parts[0]) \(parts[1].drop { $0 == " " || $0 == "\t" })")
        }
        return DemultiplexSearchRouteOwner.presentBarcodes(of: kit, inProbed: names) >= 2
    }
}
