// RNASeqCellMatcher.swift - The matcher of a given file's cells to a single-cell result's cells (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The join key is the pair (sample, barcode) as `cells.sqlite` holds them (`docs/formats/rnaseq-cell-map.md`, Matching
// cells). Pseudobulk's label table, the coordinates and labels of `rnaseq cell-map import` and a selection go through it.

import Foundation
import LungfishIO

/// Matches the (sample, barcode) pairs of a given file's lines to the result's cells (5.5 I1). A barcode matches
/// `cells.barcode` as the caller hands it, so a suffix flag changes the barcode before it gets here. The matcher refuses a
/// sample the result does not hold and a cell listed twice, in pseudobulk's words, and leaves the barcodes not held to
/// the caller, which counts them.
struct RNASeqCellMatcher {
    let samples: [RNASeqPseudobulk.SampleCells]
    let names: [String]
    private var claimed: [String: (line: Int, given: String)] = [:]

    init(samples: [RNASeqPseudobulk.SampleCells]) {
        self.samples = samples
        names = samples.map(\.name)
    }

    /// The place of the sample that line `line` of `file` names.
    func sample(_ text: String, file: String, line: Int) throws -> Int {
        guard let index = names.firstIndex(of: text) else {
            throw RNASeqPseudobulkRefusal.unknownSample(file: file, line: line, sample: text, known: names)
        }
        return index
    }

    /// Claims the cell `barcode` of sample place `sample` for line `line`, and returns its column from 1, or nil when the
    /// sample does not hold it. A cell claimed twice is refused. `given` is the barcode as the file writes it, and when
    /// it differs from the earlier line's, `changed` (such as "once -1 is dropped") follows it in the words.
    mutating func claim(sample: Int, barcode: String, file: String, line: Int, given: String? = nil, changed: String? = nil) throws -> Int? {
        let shown = given ?? barcode
        if let first = claimed.updateValue((line, shown), forKey: "\(sample)\t\(barcode)") {
            let words = first.given != shown ? changed.map { "\(shown) \($0)" } ?? shown : shown
            throw RNASeqPseudobulkRefusal.barcodeTwice(file: file, line: line, firstLine: first.line, sample: names[sample], barcode: words)
        }
        return samples[sample].columnOfBarcode[barcode]
    }
}

extension RNASeqPseudobulk {
    static func assign(labels url: URL, samples: [SampleCells]) throws -> LabelAssignment {
        let file = url.lastPathComponent
        let lines = try MatrixMarketReader.textLines(of: url)
        let header = (lines.first ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let barcodeAt = header.firstIndex(of: "barcode") else { throw RNASeqPseudobulkRefusal.missingColumn(file: file, column: "barcode") }
        guard let labelAt = header.firstIndex(of: "label") else { throw RNASeqPseudobulkRefusal.missingColumn(file: file, column: "label") }
        let sampleAt = header.firstIndex(of: "sample")
        if sampleAt == nil, samples.count >= 2 { throw RNASeqPseudobulkRefusal.noSampleColumn(file: file, samples: samples.count) }
        var matcher = RNASeqCellMatcher(samples: samples)
        let names = matcher.names
        var groupOfCell = samples.map { [Int](repeating: -1, count: $0.count) }
        var indexOfKey: [String: Int] = [:]
        var found: [(sample: Int, label: String, cells: Int)] = []
        var strays = 0
        var firstStrays: [String] = []
        for (offset, line) in lines.enumerated().dropFirst() where !line.isEmpty {
            let number = offset + 1
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == header.count else {
                throw RNASeqPseudobulkRefusal.lineCells(file: file, line: number, cells: cells.count, header: header.count)
            }
            let label = cells[labelAt]
            guard !label.isEmpty else { throw RNASeqPseudobulkRefusal.emptyLabel(file: file, line: number) }
            let sample = try sampleAt.map { try matcher.sample(cells[$0], file: file, line: number) } ?? 0
            let barcode = cells[barcodeAt]
            guard let column = try matcher.claim(sample: sample, barcode: barcode, file: file, line: number) else {
                strays += 1
                if firstStrays.count < 10 { firstStrays.append(sampleAt == nil ? barcode : "\(barcode) of \(names[sample])") }
                continue
            }
            let key = "\(sample)\t\(label)"
            let index = indexOfKey[key] ?? found.count
            if index == found.count {
                indexOfKey[key] = index
                found.append((sample, label, 0))
            }
            found[index].cells += 1
            groupOfCell[sample][column - 1] = index
        }
        if strays > 0 { throw RNASeqPseudobulkRefusal.barcodesNotHeld(file: file, count: strays, first: firstStrays) }
        let order = found.indices.sorted { a, b in
            found[a].sample != found[b].sample ? found[a].sample < found[b].sample : codePointOrder(found[a].label, found[b].label)
        }
        var rank = [Int](repeating: 0, count: found.count)
        for (position, index) in order.enumerated() { rank[index] = position }
        let groups = order.map { index in
            Group(sample: names[found[index].sample], label: found[index].label,
                  column: column(sample: names[found[index].sample], label: found[index].label), cells: found[index].cells, umis: 0)
        }
        var byColumn: [String: Group] = [:]
        for group in groups {
            if let other = byColumn.updateValue(group, forKey: group.column) {
                throw RNASeqPseudobulkRefusal.columnClash(
                    column: group.column, first: "\(other.sample) \(other.label)", second: "\(group.sample) \(group.label)")
            }
        }
        return LabelAssignment(groups: groups, groupOfCell: groupOfCell.map { columns in columns.map { $0 < 0 ? -1 : rank[$0] } })
    }
}
