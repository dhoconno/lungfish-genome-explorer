// VariantEditPinSupport.swift - Compares a variant edit's dump with its pin, or records it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fixture and the dumps moved to LungfishTestSupport (`VariantEditFixture.swift`), which the
// leaf tests of LungfishCLITests and the parity tests of LungfishAppTests link too.

import Foundation
import XCTest

/// Compares a dump with its pin, or records it when `LUNGFISH_RECORD_PINS_DIR` names a folder.
enum VariantEditPins {
    static func assertPin(
        _ name: String, actual: String, expected: [String: String] = VariantEditPinExpectations.all,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if let folder = ProcessInfo.processInfo.environment["LUNGFISH_RECORD_PINS_DIR"], !folder.isEmpty {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try actual.write(toFile: folder + "/" + name + ".txt", atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(actual, expected[name], "The pin \(name) moved", file: file, line: line)
    }
}
