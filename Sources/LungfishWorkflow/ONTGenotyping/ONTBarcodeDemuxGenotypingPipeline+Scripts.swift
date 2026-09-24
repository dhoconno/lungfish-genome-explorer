// ONTBarcodeDemuxGenotypingPipeline+Scripts.swift - Loads the ONT demux genotyping filter script
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SIMP-16 (2026-09-23 best-practices audit): this script used to live as a
// ~730-line raw string literal in this file, which meant no syntax
// highlighting, no linting, and noisy Swift diffs for every Python change.
// The script itself is unchanged (byte-identical) and now lives at
// Resources/ONTGenotyping/barcode-demux-filter.py, loaded once via
// Bundle.module.

import Foundation

extension ONTBarcodeDemuxGenotypingPipeline {
    public static func writeFilterScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
    }
}

private let filterScript: String = {
    guard let url = Bundle.module.url(
        forResource: "barcode-demux-filter",
        withExtension: "py",
        subdirectory: "ONTGenotyping"
    ), let script = try? String(contentsOf: url, encoding: .utf8) else {
        preconditionFailure("Missing bundled resource ONTGenotyping/barcode-demux-filter.py")
    }
    return script
}()
