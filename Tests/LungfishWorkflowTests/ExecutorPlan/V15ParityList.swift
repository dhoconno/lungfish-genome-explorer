// V15ParityList.swift - The closed list of V15 lines the adopt parity tests allow (CHTC C4 lane P, C4-11)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The two routes of a V15 comparison: the adopt of a returned plan folder, and the Mac import of the same sample.
enum V15Route: String, Sendable, CaseIterable {
    case adopted
    case mac
}

/// What the comparison does with a listed line.
enum V15Rule: Sendable {
    /// The value is never compared. The key must be present on each route in `mustCarry` and absent on each route in
    /// `mustLack`, where the object holding it exists.
    case notCompared(mustCarry: Set<V15Route>, mustLack: Set<V15Route> = [])
    /// Both values are printed as a `PARITY-REPORTED` line and never fail the test.
    case reported
    /// Each route must hold exactly its value, a JSON string, or JSON null when the value is nil.
    case routeValues(adopted: String?, mac: String?)
    /// JSON null on the adopted record and a number, the Mac host's value, on the Mac record (XC-7, C4-01).
    case nullOnAdoptedNumberOnMac
    /// Compared token by token after the one function that strips each route's root (XC-10). A command line joined by
    /// ` && ` compares part by part, each part one argv.
    case argv
    /// A path, or a value that holds paths, compared byte for byte after the one function strips each route's root (XC-10).
    case path
    /// A step id compares by the role of the step it names, never by UUID (XC-8, QA ruling 2).
    case byRole
}

/// One line of the closed list: the keys it covers, its N9-V15 class and the decision row that admits it.
struct V15Line: Sendable {
    let id: String
    /// The N9-V15 class of BIO's V15-R (`c3/memos/BIO-r2.md:64-89`) as XC-12 amends it.
    let n9Class: Int
    /// The decision row that admits the line (XC-1 to XC-13 of `c4/votes/tally-c4.md`, round 2's child environment).
    let decision: String
    /// Key paths, `envelope.` or `sidecar.` first. `[]` matches any array position or step, `*` one key and `**` any run
    /// of keys.
    let patterns: [String]
    let rule: V15Rule
    let reason: String
}

/// A step only one route holds (XC-8). Its own fields are not compared.
struct V15RouteOnlyStep: Sendable {
    let id: String
    let route: V15Route
    let role: String
    let decision: String
    let reason: String
}

/// C4-11's one closed list. A lane never widens it (XC-11 C): an unlisted difference fails the test and goes to the panel
/// with both values and its reason. A removal, as MO-B1's lane removes the counter step, needs only the C4-16 reviews.
enum V15ParityList {
    /// The C0 Mac determinism table's excerpt, committed beside this file (QA ruling QA-parity-1).
    static let determinismTablePath = "Tests/LungfishWorkflowTests/ExecutorPlan/mac-determinism-c0.md"

    static let routeOnlySteps: [V15RouteOnlyStep] = [
        V15RouteOnlyStep(id: "V15-S1", route: .adopted, role: V15Roles.runner, decision: "XC-8",
                         reason: "The executor's step, the runner of the node's steps on the adopt route, named lungfish-executor run."),
        V15RouteOnlyStep(id: "V15-S2", route: .adopted, role: V15Roles.counter, decision: "XC-8",
                         reason: "The counter step Count Q20 and Q30 bases, until MO-B1's lane records that step on the Mac route and deletes this entry."),
        V15RouteOnlyStep(id: "V15-S3", route: .adopted, role: V15Roles.adoptStep, decision: "XC-8",
                         reason: "The adopt step, the run's last step in place of the import step (V12)."),
        V15RouteOnlyStep(id: "V15-S4", route: .mac, role: V15Roles.runner, decision: "XC-8",
                         reason: "The Mac's import step lungfish import fastq, the runner of the Mac's steps and the adopt step's counterpart."),
        // C4-3 C-3: the adopt route's fourth route-only step. The harness asserts each one's program is the plan's pin.
        V15RouteOnlyStep(id: "V15-S5", route: .adopted, role: V15Roles.decompressor, decision: "XC-8 A, C4-3 C-3",
                         reason: "Each decompressor the node's interleave step started for a gzip input, one step per launch the record holds. The Mac's interleave also starts /usr/bin/gzip -dc through ToolProcess and records no step, so only the adopt route holds these."),
    ]

    static let lines: [V15Line] = [
        // Class 1. Where or with what binary a step ran.
        V15Line(id: "V15-01", n9Class: 1, decision: "XC-12 (V15-R class 1)",
                patterns: ["envelope.runtimeIdentity", "envelope.steps[].runtimeIdentity"],
                rule: .notCompared(mustCarry: []),
                reason: "Host, platform, kernel and runtime identity of the run and of each step."),
        V15Line(id: "V15-02", n9Class: 1, decision: "XC-4 B",
                patterns: ["envelope.steps[].toolVersionEvidence", "envelope.steps[].resolvedOptions.tool"],
                rule: .notCompared(mustCarry: []),
                reason: "The line that names where a tool's version came from: imageManifest or planPin on the node, the Mac's toolVersionEvidence kind on the Mac, and the node tool's build, path and version source under resolvedOptions.tool. The version itself is compared, and the comparison asserts the node tool's version equals the step's toolVersion (QV-17)."),
        V15Line(id: "V15-03", n9Class: 1, decision: "XC-4 B",
                patterns: ["**.tool.path", "**.tool.build", "**.tool.versionSource"],
                rule: .notCompared(mustCarry: []),
                reason: "A tool's path and build string as a route states them."),
        V15Line(id: "V15-04", n9Class: 1, decision: "XC-5 A",
                patterns: ["**.siteFacts", "**.executorArguments"],
                rule: .notCompared(mustCarry: []),
                reason: "The node's site facts and the executor's own arguments with their --site-fact pairs. No site file is named."),
        V15Line(id: "V15-05", n9Class: 1, decision: "Round 2, child environment A",
                patterns: ["**.environmentNames", "**.searchPath", "**.runtimes"],
                rule: .notCompared(mustCarry: []),
                reason: "The node's environment names, PATH folders and runtimes. The values that change a result sit in the plan, whose digest is compared."),
        V15Line(id: "V15-06", n9Class: 1, decision: "XC-12 (V15-R class 1), tally-c4r2 item 11",
                patterns: ["**.containerImage", "**.containerDigest", "**.imageManifest", "**.executor.sha256", "**.executor.size",
                           "**.subreaper", "**.orphanSweep"],
                rule: .notCompared(mustCarry: []),
                reason: "The image and executor digests, the executor's identity and the subreaper result."),
        // Before V15-07, since `line(for:)` takes the first match and `**.argv` matches `envelope.argv` (QV-22).
        V15Line(id: "V15-24", n9Class: 2, decision: "XC-8 A, CLI-EQUIVALENCE \"Same provenance\"",
                patterns: ["envelope.argv", "envelope.durableReplayArgv", "envelope.reproducibleCommand",
                           "envelope.options.explicit.r1", "envelope.options.explicit.r2",
                           "envelope.options.resolvedDefaults.r1", "envelope.options.resolvedDefaults.r2"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The run-level argv is the route's own command, the import step's or the adopt step's, the two route-only steps whose fields are not compared. Every other options key stays compared."),
        V15Line(id: "V15-25", n9Class: 2, decision: "XC-8 A",
                patterns: ["envelope.id"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The envelope's id names the route's own record, whose counterpart is the other route's; ids compare by what they name, never by UUID (QV-26)."),
        V15Line(id: "V15-26", n9Class: 1, decision: "XC-10 B as amended by C4-3 C-2, XC-6 B scratch folder names",
                patterns: ["**.executionOutputFiles.*.path", "**.databases.*.path", "**.auxiliaryCommandPathRewrites",
                           "envelope.steps[].inputs.*.path", "envelope.steps[].outputs.*.path",
                           "envelope.steps[].resolvedOptions.databases",
                           // QV-23: the run's outputs and files list the steps' files, whose paths fall under QV-10 and QV-11.
                           "envelope.outputs.*.path", "envelope.files.*.path"],
                rule: .path,
                reason: "Path keys that hold argv paths, the envelope's typed database block whole among them (QV-10): each goes through the one function that strips the route's roots and maps C4-3 C-2's work stem, work folder, report UUID and inputs by digest, and then compares byte for byte, with no last-component rule."),
        V15Line(id: "V15-07", n9Class: 1, decision: "XC-10 B as amended by C4-3 C-2",
                patterns: ["**.argv", "**.durableReplayArgv", "**.commandArguments", "**.reproducibleCommand", "**.commandLine",
                           "**.processingCommandLine"],
                rule: .argv,
                reason: "Each argv token by token after the one function that strips the route's root and maps C4-3 C-2's work stem, work folder, report UUID and inputs by digest. The executable token compares by its last path component and is never set aside."),

        // Class 2 is `routeOnlySteps`, and step ids compare by role.
        V15Line(id: "V15-08", n9Class: 2, decision: "XC-8 A, QA ruling 2",
                patterns: ["envelope.steps[].id", "envelope.steps[].parentStepID", "envelope.steps[].dependsOn"],
                rule: .byRole,
                reason: "Step ids, parentStepID and dependsOn compare by the role of the step each names, never by UUID."),

        // Class 3. Where a value came from.
        V15Line(id: "V15-09", n9Class: 3, decision: "XC-13 A",
                patterns: ["**.threadsSource"], rule: .routeValues(adopted: "plan", mac: "option"),
                reason: "plan on the adopted record, option on the Mac import that passes every setting."),
        V15Line(id: "V15-10", n9Class: 3, decision: "XC-13 A",
                patterns: ["**.clumpifyHeapSource"], rule: .routeValues(adopted: "plan", mac: "option"),
                reason: "plan on the adopted record, option on the Mac import that passes the plan's heap."),
        V15Line(id: "V15-11", n9Class: 3, decision: "XC-13 A",
                patterns: ["**.resolvedClumpingToolSource"], rule: .routeValues(adopted: "plan", mac: "option"),
                reason: "plan on the adopted record, option on the Mac import that passes bbtools."),
        V15Line(id: "V15-12", n9Class: 3, decision: "XC-13 A, the manager's fourth source key",
                patterns: ["**.qualityBinningSource"], rule: .routeValues(adopted: "plan", mac: "option"),
                reason: "plan on the adopted record, since the plan fixes binning, option on the Mac import that passes it."),
        V15Line(id: "V15-13", n9Class: 3, decision: "XC-7 B, C4-01",
                patterns: ["**.clumpingEstimatedInputBytes", "**.clumpingPhysicalMemoryBytes", "**.clumpingThresholdBytes"],
                rule: .nullOnAdoptedNumberOnMac,
                reason: "Null on the adopted record, since no decision of the plan used them, and the Mac host's value on the Mac."),

        // Class 4. Lines in which the Mac differs from itself.
        V15Line(id: "V15-14", n9Class: 4, decision: "XC-6 B, QA ruling 1",
                patterns: ["**.createdAt", "**.startedAt", "**.completedAt", "**.endedAt", "**.ingestionDate", "**.appliedDate",
                           "**.recordedAt"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "Dates and start and end times. mac-determinism-c0.md measures start times and shows them differing between two Mac runs; it holds no row for the two date keys, which stand on the class as voted."),
        V15Line(id: "V15-15", n9Class: 4, decision: "XC-6 B, QA ruling 1",
                patterns: ["**.wallTimeSeconds", "**.wallSeconds", "**.durationSeconds"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "Wall times and durations. mac-determinism-c0.md measures wall seconds and shows them differing between two Mac runs."),
        // AMV1 QA fix 3: XC-6 B tests that each listed key is present on the route that must carry it, and never compares
        // its value. peakMemoryBytes is the envelope step's key on both routes and stderr is the Mac envelope's; the names
        // only the node's run record holds (peakResidentBytes, stderrTail, stderrTruncated, stderrBytes) are V15-16b and V15-17b.
        // C4-4 D-1: XC-6 B's presence clause for peakMemoryBytes holds for the adopted route only, and the Mac's absence is
        // this line's own (Phase 2.7 decision P4). A Mac change that records the key edits this line in its own commit.
        V15Line(id: "V15-16", n9Class: 4, decision: "XC-6 B as amended by C4-4 D-1, QA ruling 1",
                patterns: ["**.peakMemoryBytes"],
                rule: .notCompared(mustCarry: [.adopted], mustLack: [.mac]),
                reason: "Peak memory, peakMemoryBytes on each envelope step: the node records it from ru_maxrss and the adopt carries it unchanged, and the Mac records none, since no Mac record reads ToolProcess's observedPeakMemoryBytes until a golden normalizer rule for it is approved (Phase 2.7 decision P4, ProvenanceStepObservation.swift:14-16, ToolProcessObservation.swift:225-232). Never compared: each adopted tool step must carry it above 0 and every Mac step must lack it. mac-determinism-c0.md does not measure it; it stands on the class as voted."),
        V15Line(id: "V15-16b", n9Class: 4, decision: "XC-6 B, QA ruling 1",
                patterns: ["**.peakResidentBytes"],
                rule: .notCompared(mustCarry: []),
                reason: "Peak resident bytes, held by the run record only; the walk reads no run record. mac-determinism-c0.md does not measure it; it stands on the class as voted."),
        // C4-4 D-6 (CH-8): the node's peak scratch disk, a node-only key of the storage step's record.
        V15Line(id: "V15-16c", n9Class: 4, decision: "XC-6 B run-varying class, C4-4 D-6 (CH-8)",
                patterns: ["**.peakWorkRootBytes"],
                rule: .notCompared(mustCarry: []),
                reason: "The largest size the run folder reached while the storage step ran, storage.peakWorkRootBytes, from the executor's own walk every quarter second (lane W0): a node-only key, held by the run record and by the adopted record where the adopt carries it, with no Mac counterpart. It varies from run to run and is never compared. mac-determinism-c0.md does not measure it; it stands on the class as voted."),
        V15Line(id: "V15-17", n9Class: 4, decision: "XC-6 B, QA ruling 1",
                patterns: ["**.stderr"],
                rule: .notCompared(mustCarry: [.mac]),
                reason: "Standard error text, stderr on the Mac's records: the value is never compared, and the Mac route must carry the key. mac-determinism-c0.md does not measure it, nor scratch folder names; they stand on the class as voted."),
        V15Line(id: "V15-17b", n9Class: 4, decision: "XC-6 B, QA ruling 1",
                patterns: ["**.stderrTail", "**.stderrTruncated", "**.stderrBytes"],
                rule: .notCompared(mustCarry: []),
                reason: "Standard error tail, truncation flag and byte count, held by the run record only; the walk reads no run record. mac-determinism-c0.md does not measure it; they stand on the class as voted."),

        // Class 5. Lines that follow compressed bytes or the read order.
        V15Line(id: "V15-18", n9Class: 5, decision: "XC-1 A",
                patterns: ["**.storageOutputSizeBytes", "**.finalSizeBytes"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The stored payload's size, recorded in both records and never compared."),
        V15Line(id: "V15-19", n9Class: 5, decision: "XC-1 A",
                patterns: ["payload-file.checksumSHA256", "payload-file.fileSize"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The SHA-256 and size of the payload and of each file that holds one of its values (the sidecar), recorded and never compared."),
        V15Line(id: "V15-20", n9Class: 5, decision: "XC-1 A",
                patterns: ["envelope.signatures"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The signature of the envelope, a file that holds the payload's SHA-256 and size."),
        V15Line(id: "V15-21", n9Class: 5, decision: "XC-2 A",
                patterns: ["**.clumpifyGroups", "**.clumpifyMemoryEstimate", "**.clumpifyMemoryAvailable",
                           "**.clumpifyMemoryEstimateLine", "**.clumpifyMemoryAvailableLine"],
                rule: .reported,
                reason: "Clumpify's group count and its memory lines, printed for both routes and never failing."),
        V15Line(id: "V15-22", n9Class: 5, decision: "XC-3 A",
                patterns: ["payload.e4"],
                rule: .reported,
                reason: "E4, the digest of the decompressed stream in stored order, reported and never failing."),

        // XC-9. The statistics step's output.
        V15Line(id: "V15-23", n9Class: 1, decision: "XC-9 A",
                patterns: ["envelope.steps[statistics].outputs", "envelope.steps[statistics].inputs"],
                rule: .notCompared(mustCarry: []),
                reason: "The seqkit stats step's output: the node's standardOutput and inputFile on the adopt route, the sidecar the step names on the Mac. Every value seqkit printed is parsed and compared."),

        // C4-3 C-4 (a), QV-OQ1, A-C4-1. `bgzip#1` is the BBTools writer step, the one step the line names (AMV2 ARCH fix 5).
        V15Line(id: "V15-27", n9Class: 1, decision: "XC-4 B, C4-3 C-4 (a)",
                patterns: ["envelope.steps[bgzip#1].managedToolID"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "BBTools takes the first bgzip on its PATH (PortableStorageStep+WriterProbe.swift:7-8), so the environment a writer comes from is a fact of each route's path: bbtools on the node, htslib on the Mac. A route-shaped line for the writer step bgzip#1 only: carried on both routes and not compared, and each route's value must be the envs/<id>/ folder of that step's own program. The version is compared, and the node refuses a writer whose version is not the plan's pin."),

        // C4-4 D-4: the recipe reports' own bytes state their run's command line and times, so two Mac runs differ too.
        V15Line(id: "V15-28", n9Class: 4, decision: "XC-6 B as amended by C4-4 D-4, QA ruling 1",
                patterns: ["report-file.checksumSHA256", "report-file.fileSize"],
                rule: .notCompared(mustCarry: [.adopted, .mac]),
                reason: "The SHA-256 and size of each recipe step's report copy, a fastp JSON or a deacon summary under metadata/recipe-step-artifacts/: a report states its own run's command line and times, so two Mac runs of one input give different bytes (fastp#1 outputs[2] reads cd597e72 in V2.md:414 and 16d67680 in AMV1-fix-F1.md:80). Recorded on both routes and never compared. Each route's copy must hash to its record's digest and size, and the harness parses both copies and compares every value but the command line, the paths and the times (V15Reports). mac-determinism-c0.md does not measure it; it stands on the class as voted."),
    ]
}

/// The roles of QA ruling 2.
enum V15Roles {
    static let runner = "runner"
    static let adoptStep = "adopt-step"
    static let counter = "counter-step"
    static let statistics = "statistics"
    static let decompressor = "decompressor"
}
