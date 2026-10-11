// ProvenanceStepParentSupport.swift - What the step parent test classes share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

enum StepParentSupport {
    /// The project folder the synthetic records name.
    static let project = "/Users/tester/Demo.lungfish"

    /// The lines of `script` that run something: no comment, no blank line and none of the fixed
    /// preamble every script opens with.
    static func commandLines(of script: String) -> [String] {
        let preamble = ["set ", "PROJECT=", "OUTDIR=", "mkdir ", "INPUT_", "echo "]
        return script.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
            !line.hasPrefix("#") && !preamble.contains { line.hasPrefix($0) }
        }
    }
}

extension XCTestCase {
    /// A fresh temporary folder, removed when the test ends.
    func makeStepParentDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("step-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }
}
