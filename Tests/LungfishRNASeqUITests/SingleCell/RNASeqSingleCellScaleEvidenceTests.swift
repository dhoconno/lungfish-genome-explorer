// RNASeqSingleCellScaleEvidenceTests.swift - Lane evidence of the view on the 500,000-cell result (lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Not in a gate (prog:268). Set LUNGFISH_RS_SC_VIEW_X5_RESULT to a `.lungfishrnaseq` folder that the CLI imported from
// the X5 matrix of lane RS-SC-IMPORT, and this test opens the result's view model, reads the summary, the first page and
// the three histograms, and prints the wall and the growth of this process's footprint. The growth is the kernel's
// lifetime peak after the reads less the footprint before them, so run this test alone, where no earlier test set the
// peak. The bound is under 600 s and under 1 GiB (`SCR/lanes/SPIKE-STREAM.md:86-97`). With the variable unset it reads
// nothing and passes.

import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishRNASeqUI

final class RNASeqSingleCellScaleEvidenceTests: XCTestCase {
    static let variable = "LUNGFISH_RS_SC_VIEW_X5_RESULT"

    /// This process's `phys_footprint` and the kernel's lifetime peak of it, or zeros when the kernel does not answer.
    static func footprint() -> (now: Int64, peak: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? (Int64(info.phys_footprint), info.ledger_phys_footprint_peak) : (0, 0)
    }

    @MainActor
    func testTheViewOfTheX5ResultReadsWithinTheBound() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.variable], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let before = Self.footprint()
        let clock = ContinuousClock()
        let began = clock.now
        let result = try RNASeqResultBundle.load(from: url)
        let view = RNASeqSingleCellViewController(nibName: nil, bundle: nil)
        view.configure(result: result, bundleURL: url)
        await view.loading?.value
        let summary = try XCTUnwrap(view.summary, view.failureWords ?? "no summary")
        let source = try XCTUnwrap(view.tableSource)
        let page = try source.pages.page(0)
        let wall = clock.now - began
        let after = Self.footprint()
        let growth = max(after.peak, after.now) - before.now
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        print("RS-SC-VIEW X5 result=\(path)")
        print("RS-SC-VIEW X5 cells=\(summary.cellCount) samples=\(summary.samples.map { "\($0.name):\($0.cells):\($0.features):\($0.entries)" })")
        print("RS-SC-VIEW X5 tool=\(summary.tool) version=\(summary.toolVersion) quality_rows=\(summary.quality?.rows.count ?? 0)")
        print("RS-SC-VIEW X5 page0=\(page.count) first=\(page.first.map { "\($0.cell.cell) \($0.cell.barcode) \($0.cell.umis) \($0.cell.genes)" } ?? "none")")
        for histogram in summary.histograms {
            print("RS-SC-VIEW X5 histogram \(histogram.id) bins=\(histogram.bins.map(\.cells))")
        }
        print("RS-SC-VIEW X5 notHost=\(summary.notHost.count) rankSteps=\(summary.rankSteps.count) words=\(view.failureWords ?? "none")")
        print("RS-SC-VIEW X5 wall_s=\(seconds) footprint_before=\(before.now) peak_before=\(before.peak) footprint_after=\(after.now) peak_after=\(after.peak) growth=\(growth)")
        XCTAssertEqual(page.count, min(RNASeqSingleCellPages.pageSize, summary.cellCount))
        XCTAssertEqual(summary.umis.bins.reduce(0) { $0 + $1.cells }, summary.cellCount)
        XCTAssertLessThan(seconds, 600)
        XCTAssertLessThan(growth, 1 << 30)
        view.close()
    }
}
