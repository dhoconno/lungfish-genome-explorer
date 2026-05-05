// IQTreeInferenceOptions.swift - IQ-TREE runner options
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

struct IQTreeInferenceOptions: Equatable, Sendable {
    var outputName: String
    var model: String
    var sequenceType: String
    var bootstrap: Int?
    var alrt: Int?
    var seed: Int?
    var threads: Int?
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var iqtreePath: String?
    var extraIQTreeOptions: String

    static func defaults(outputName: String) -> IQTreeInferenceOptions {
        IQTreeInferenceOptions(
            outputName: outputName,
            model: "MFP",
            sequenceType: "Auto",
            bootstrap: nil,
            alrt: nil,
            seed: 1,
            threads: nil,
            safeMode: false,
            keepIdenticalSequences: false,
            iqtreePath: nil,
            extraIQTreeOptions: ""
        )
    }
}
