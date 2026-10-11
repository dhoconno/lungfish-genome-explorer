// AnalysisRunRequest.swift - The request of one analysis command run, and the plan and units a tool makes of it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Where the executor puts a run's result folder.
public enum AnalysisRunDestination: Sendable, Equatable {
    /// A project. The executor creates `Analyses/<tool>-<timestamp>/`, or
    /// `Analyses/<tool>-batch-<timestamp>/` for either batch layout, with `analysis-metadata.json`
    /// and a run record that names the command, as the app's windows do (E1). A replay makes a new
    /// folder and never overwrites an earlier result.
    case project(URL)
    /// A folder the caller named, such as `--output-dir`. The executor claims it with a run record
    /// when it sits inside a project (`AnalysesFolder.beginRunInOutputDirectory`), creates it when
    /// it is missing and writes the same `analysis-metadata.json`.
    case directory(URL)

    /// The project the result folder belongs to, when it belongs to one.
    public var projectURL: URL? {
        switch self {
        case .project(let projectURL):
            return projectURL.standardizedFileURL
        case .directory(let directory):
            return ProjectTempDirectory.findProjectRoot(directory.standardizedFileURL)
        }
    }
}

/// One analysis command run, as the command was given.
public struct AnalysisRunRequest: Sendable, Equatable {
    /// The inputs as chosen, bundles or files.
    public var inputs: [URL]
    public var destination: AnalysisRunDestination
    /// Whether the command was given `--batch`. The tool's plan picks the layout from it and the
    /// number of samples (E2, E8).
    public var groupsSamples: Bool
    /// The `lungfish-cli` argv that runs this request. It is the root record's argv and the run
    /// record's command, so the record names the command that ran.
    public var commandLine: [String]
    /// The argv a replay runs, when the command records one. Nil records none.
    public var durableReplayArgv: [String]?

    public init(
        inputs: [URL],
        destination: AnalysisRunDestination,
        groupsSamples: Bool = false,
        commandLine: [String],
        durableReplayArgv: [String]? = nil
    ) {
        self.inputs = inputs
        self.destination = destination
        self.groupsSamples = groupsSamples
        self.commandLine = commandLine
        self.durableReplayArgv = durableReplayArgv
    }
}

/// The plan a tool makes of a request in phase P0.
public struct AnalysisRunPlan<Value: Sendable>: Sendable {
    public var layout: AnalysisRunLayout
    /// The units in the order they run. A plan holds at least one.
    public var units: [AnalysisRunPlannedUnit<Value>]
    /// The options of the root record, which the units and the finalize may add to.
    public var options: AnalysisRootRecordOptions
    /// Inputs of the root record that the plan already described, such as a database reference.
    /// The executor hashes none of them again (see ``AnalysisRunUnitContext/recordInput(_:)``).
    public var recordInputs: [ProvenanceFileDescriptor]

    public init(
        layout: AnalysisRunLayout,
        units: [AnalysisRunPlannedUnit<Value>],
        options: AnalysisRootRecordOptions = AnalysisRootRecordOptions(),
        recordInputs: [ProvenanceFileDescriptor] = []
    ) {
        self.layout = layout
        self.units = units
        self.options = options
        self.recordInputs = recordInputs
    }
}

/// One unit of a plan.
public struct AnalysisRunPlannedUnit<Value: Sendable>: Sendable {
    /// The sample name, or another name for a unit that holds several samples. In a
    /// ``AnalysisRunLayout/batchRoot`` layout the unit's folder takes this name, sanitized and
    /// made unique.
    public var label: String
    public var value: Value

    public init(label: String, value: Value) {
        self.label = label
        self.value = value
    }
}

/// The options the root record holds.
///
/// The executor starts from the plan's options and merges each contribution in the order it
/// arrives, a unit's through ``AnalysisRunUnitContext/recordOptions(_:)`` and then the
/// finalization's ``AnalysisRunFinalization/options``. It merges key by key into `explicit`,
/// `defaults` and `resolved`, a later value winning, and a non-nil `readSetPlan` replaces the one
/// before. Options recorded before a failure or a cancel reach that run's record, as recorded
/// inputs and steps do. In a batch the unit records keep the facts of each sample and a unit adds
/// only run-level values. How a batch root records `readSetPlan` across its samples is the tool's
/// to settle.
public struct AnalysisRootRecordOptions: Sendable, Equatable {
    /// The key of the read-set plan in the resolved options, its one home (E13).
    public static let readSetPlanKey = "readSetPlan"

    public var explicit: [String: ParameterValue]
    public var defaults: [String: ParameterValue]
    public var resolved: [String: ParameterValue]
    /// The run's read-set plan, as `ReadSetPlan.provenanceParameters` holds it under
    /// ``readSetPlanKey``. The executor writes it into `options.resolvedDefaults`, and nil
    /// writes nothing.
    public var readSetPlan: ParameterValue?

    public init(
        explicit: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolved: [String: ParameterValue] = [:],
        readSetPlan: ParameterValue? = nil
    ) {
        self.explicit = explicit
        self.defaults = defaults
        self.resolved = resolved
        self.readSetPlan = readSetPlan
    }

    /// The value a read-set plan records, or nil for no plan and for a plan that records nothing
    /// new, so a run of only single reads or only pairs records as it always did.
    public static func readSetPlanValue(of plan: ReadSetPlan?) -> ParameterValue? {
        plan?.provenanceParameters[readSetPlanKey]
    }

    /// The resolved options with the read-set plan under ``readSetPlanKey``. The plan replaces
    /// any value `resolved` holds under that key.
    public var resolvedIncludingReadSetPlan: [String: ParameterValue] {
        guard let readSetPlan else { return resolved }
        var merged = resolved
        merged[Self.readSetPlanKey] = readSetPlan
        return merged
    }

    /// These options with `later` merged in by the rule above, key by key with the later value
    /// winning, and `later`'s read-set plan replacing this one when it has one.
    func merging(_ later: AnalysisRootRecordOptions) -> AnalysisRootRecordOptions {
        AnalysisRootRecordOptions(
            explicit: explicit.merging(later.explicit) { _, new in new },
            defaults: defaults.merging(later.defaults) { _, new in new },
            resolved: resolved.merging(later.resolved) { _, new in new },
            readSetPlan: later.readSetPlan ?? readSetPlan
        )
    }
}

/// A unit as the executor hands it to ``AnalysisRunTool/run(_:context:)``.
public struct AnalysisRunUnit<Value: Sendable>: Sendable {
    /// The unit's place in the plan, from 0.
    public let index: Int
    /// The number of units in the plan.
    public let count: Int
    /// The label the plan gave the unit.
    public let label: String
    /// The name the tool gives its sample. In a ``AnalysisRunLayout/batchRoot`` layout it is the
    /// name of the unit's folder, so the tool's own sample label equals the folder name.
    /// Otherwise it is the label.
    public let sampleName: String
    /// Where the unit writes. A unit folder in a ``AnalysisRunLayout/batchRoot`` layout, else the
    /// result folder itself.
    public let directory: URL
    public let value: Value

    public init(index: Int, count: Int, label: String, sampleName: String, directory: URL, value: Value) {
        self.index = index
        self.count = count
        self.label = label
        self.sampleName = sampleName
        self.directory = directory
        self.value = value
    }
}

/// A file the root record lists as an output, which the executor hashes once, when it writes the
/// root record of a completed run.
public struct AnalysisRunOutput: Sendable, Equatable {
    public var url: URL
    public var format: FileFormat?
    public var role: FileRole

    public init(url: URL, format: FileFormat? = nil, role: FileRole = .output) {
        self.url = url
        self.format = format
        self.role = role
    }
}
