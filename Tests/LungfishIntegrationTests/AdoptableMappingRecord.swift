// AdoptableMappingRecord.swift - A typed mapping-provenance.json that a mapping folder can hold, for the adopt-mapping tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

/// A real typed `mapping-provenance.json`, taken from the golden record of a `lungfish map` run in
/// `Tests/Fixtures/golden/mapping`. The golden is read here and never edited. It holds a token in
/// place of each value that changes with every run (a date, a duration, a size, a run folder, an id),
/// so this fills the tokens with fixed values and the result decodes as the record a run writes.
enum AdoptableMappingRecord {
    /// Where the record holds the plan that says how a mixed sample's reads reached the mapper.
    enum PlanHome {
        /// No plan, as a run of only single reads or only pairs writes it.
        case none
        /// At the record's own level, as a build since 2.7 writes it.
        case recordLevel([String: ParameterValue])
        /// In the `resolvedOptions` of the mapper step, as released builds wrote a mixed sample.
        case mapperStep([String: ParameterValue])
    }

    /// The plan of a mixed sample of one pair and three merged reads that one run of a stream mapper read.
    static let mixedSamplePlan: [String: ParameterValue] = [
        "capability": .string("both_in_one_run/name_interleaved_stream"),
        "pairedFragments": .integer(1),
        "mergedReads": .integer(3),
        "runs": .integer(1),
    ]

    static var goldenRecordURL: URL {
        ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/golden/mapping/\(MappingProvenance.filename)")
    }

    /// Writes the record into `folder` and returns its URL. The bytes are the same on every call.
    @discardableResult
    static func write(into folder: URL, planHome: PlanHome = .none) throws -> URL {
        let url = folder.appendingPathComponent(MappingProvenance.filename)
        try data(planHome: planHome).write(to: url)
        return url
    }

    static func data(planHome: PlanHome = .none) throws -> Data {
        let golden = try Data(contentsOf: goldenRecordURL)
        guard var record = denormalized(try JSONSerialization.jsonObject(with: golden)) as? [String: Any] else {
            throw Failure(description: "the golden mapping record is not a JSON object")
        }
        switch planHome {
        case .none:
            break
        case .recordLevel(let plan):
            record["readSetPlan"] = try encoded(plan)
        case .mapperStep(let plan):
            guard var steps = record["steps"] as? [[String: Any]],
                  let index = steps.firstIndex(where: { ($0["toolName"] as? String) == "minimap2" }) else {
                throw Failure(description: "the golden mapping record has no minimap2 step")
            }
            steps[index]["resolvedOptions"] = ["readSetPlan": try encoded(plan)]
            record["steps"] = steps
        }
        return try JSONSerialization.data(
            withJSONObject: record,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func encoded(_ plan: [String: ParameterValue]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(ParameterValue.dictionary(plan)))
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let runRoot = "/var/empty/golden-mapping-run"

    private static func denormalized(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return denormalized(text)
        case let items as [Any]:
            return items.map(denormalized)
        case let members as [String: Any]:
            return members.mapValues(denormalized)
        default:
            return value
        }
    }

    private static func denormalized(_ text: String) -> Any {
        if text == "<EPOCH>" { return 800_000_000.0 }
        if text == "<DURATION>" { return 1.5 }
        if text.hasPrefix("<SIZE-"), text.hasSuffix(">") { return 4096 }
        var result = text.replacingOccurrences(of: "<RUN_ROOT>", with: runRoot)
        for number in 1...9 {
            result = result.replacingOccurrences(
                of: "<UUID-\(number)>",
                with: "00000000-0000-0000-0000-00000000000\(number)"
            )
        }
        return result
    }
}
