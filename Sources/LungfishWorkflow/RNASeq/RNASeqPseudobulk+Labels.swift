// RNASeqPseudobulk+Labels.swift - The label table of rnaseq pseudobulk and its groups (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The table is tab-separated with a header, plain or gzip, with `barcode`, `label` and, for a result of two or more
// samples, `sample`. A barcode matches `cells.barcode` as given. Every line is checked before the pass reads a matrix.

import Foundation
import LungfishIO

extension RNASeqPseudobulk {
    /// One sample's cells as `cells.sqlite` lists them, each barcode with its column in the matrix, from 1.
    struct SampleCells {
        var name: String
        var count: Int
        var columnOfBarcode: [String: Int]
    }

    /// Every group in column order, kept and dropped alike, and for each sample the group of each column or -1.
    struct LabelAssignment {
        var groups: [Group]
        var groupOfCell: [[Int]]
    }

    static func assign(labels url: URL, samples: [SampleCells]) throws -> LabelAssignment {
        let file = url.lastPathComponent
        let lines = try MatrixMarketReader.textLines(of: url)
        let header = (lines.first ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let barcodeAt = header.firstIndex(of: "barcode") else { throw RNASeqPseudobulkRefusal.missingColumn(file: file, column: "barcode") }
        guard let labelAt = header.firstIndex(of: "label") else { throw RNASeqPseudobulkRefusal.missingColumn(file: file, column: "label") }
        let sampleAt = header.firstIndex(of: "sample")
        if sampleAt == nil, samples.count >= 2 { throw RNASeqPseudobulkRefusal.noSampleColumn(file: file, samples: samples.count) }
        let names = samples.map(\.name)
        var groupOfCell = samples.map { [Int](repeating: -1, count: $0.count) }
        var indexOfKey: [String: Int] = [:]
        var found: [(sample: Int, label: String, cells: Int)] = []
        var lineOfCell: [String: Int] = [:]
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
            var sample = 0
            if let sampleAt {
                guard let index = names.firstIndex(of: cells[sampleAt]) else {
                    throw RNASeqPseudobulkRefusal.unknownSample(file: file, line: number, sample: cells[sampleAt], known: names)
                }
                sample = index
            }
            let barcode = cells[barcodeAt]
            if let first = lineOfCell.updateValue(number, forKey: "\(sample)\t\(barcode)") {
                throw RNASeqPseudobulkRefusal.barcodeTwice(file: file, line: number, firstLine: first, sample: names[sample], barcode: barcode)
            }
            guard let column = samples[sample].columnOfBarcode[barcode] else {
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
