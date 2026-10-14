// NextflowWorkflowDescriptor.swift - One Nextflow workflow as data, resolved against the managed tool lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (panel N1, N3, N4, W2 and W3). The descriptor holds what LGE needs to launch one
// Nextflow workflow and nothing a lock entry already holds. The repository, commit and tag of a run come
// only from the lock, and a lock with no pin for the workflow refuses the run at plan, before any folder
// exists, with no fallback revision (N4). The types take `package` access, so the module map gains no
// public type (N3).

import Foundation
import LungfishIO

/// One Nextflow workflow as data, resolved against the managed tool lock with no fallback revision.
///
/// The descriptor names its analysis kind by ``toolID`` and its lock pipeline by ``lockPipelineID``,
/// and an agreement test holds that id equal to the registry's `.lockedPipeline` id. It holds no
/// repository, commit or tag of its own. Those come from the lock through ``resolvePin(in:)``, which
/// refuses a lock that has no pin for the workflow (decision N4), so a missing pin never falls back to a
/// branch such as `main`.
package struct NextflowWorkflowDescriptor: Sendable, Equatable {
    /// The analysis kind, which names the result folder and keys the registry row.
    package let toolID: AnalysisToolID
    /// The id of the workflow's entry in the lock's `pipelines`, such as `nf-core-viralrecon`.
    package let lockPipelineID: String
    /// The Nextflow profile a run passes as `-profile`.
    package let profile: String
    /// Whether the workflow's tasks need the Docker daemon, so the engine waits for it first (N9).
    package let containerRuntime: NextflowContainerRuntime
    /// Environment settings the engine needs for one release, keyed by the release tag the lock pins
    /// (`releaseVersion`). A release with no entry adds nothing.
    package let releaseEnvironment: [String: [String: String]]
    /// The path of the workflow's parameter schema inside the pipeline checkout, or nil when LGE reads
    /// none.
    package let parameterSchemaPath: String?
    /// The option that names the work folder, `-w` or `-work-dir`.
    package let workDirectoryOption: String
    /// The name of the trace file a run writes into its output folder, or nil when it writes none.
    package let traceFileName: String?
    /// How ``nextflowArguments(for:)`` orders a launch's options after the target, as the workflow's
    /// launch writes them today.
    package let argumentLayout: NextflowArgumentLayout
    /// The name prefix of a run's scratch folder, the launch folder that holds `.nextflow/` and the work
    /// folder.
    package let scratchPrefix: String
    /// The environment variable that keeps the scratch after a run when it is `1`, or nil when the
    /// workflow has none.
    package let keepWorkEnvironmentKey: String?
    /// How many tasks one sample runs, which the progress bar counts against, or nil to keep the
    /// engine's own estimate (W2).
    package let expectedTaskCountPerSample: Int?
    /// The share at the end of the progress bar that the finalize phase takes, at least 0 and less than
    /// 1 (W3). The engine moves the bar from 0 to `1 - finalizeProgressShare`. This is the share of a
    /// result whose finalize has work to do, a result in a project or a batch root. A layout whose
    /// finalize has none, as TaxTriage's plain `--output` has, takes no share, so the tool answers 0 for
    /// it through ``AnalysisRunTool/finalizeProgressShare(for:)`` and its engine ends the bar at 100
    /// percent (W1 of Phase 2.10, Q-U33).
    package let finalizeProgressShare: Double

    /// A workflow's facts. Every field is stated, so a new workflow decides each one.
    ///
    /// - Precondition: `finalizeProgressShare` is at least 0 and less than 1, and
    ///   `expectedTaskCountPerSample` is nil or positive.
    package init(
        toolID: AnalysisToolID,
        lockPipelineID: String,
        profile: String,
        containerRuntime: NextflowContainerRuntime,
        releaseEnvironment: [String: [String: String]],
        parameterSchemaPath: String?,
        workDirectoryOption: String,
        traceFileName: String?,
        argumentLayout: NextflowArgumentLayout,
        scratchPrefix: String,
        keepWorkEnvironmentKey: String?,
        expectedTaskCountPerSample: Int?,
        finalizeProgressShare: Double
    ) {
        precondition(
            finalizeProgressShare >= 0 && finalizeProgressShare < 1,
            "A finalize share is at least 0 and less than 1"
        )
        precondition(
            expectedTaskCountPerSample.map { $0 > 0 } ?? true,
            "An expected task count is positive"
        )
        self.toolID = toolID
        self.lockPipelineID = lockPipelineID
        self.profile = profile
        self.containerRuntime = containerRuntime
        self.releaseEnvironment = releaseEnvironment
        self.parameterSchemaPath = parameterSchemaPath
        self.workDirectoryOption = workDirectoryOption
        self.traceFileName = traceFileName
        self.argumentLayout = argumentLayout
        self.scratchPrefix = scratchPrefix
        self.keepWorkEnvironmentKey = keepWorkEnvironmentKey
        self.expectedTaskCountPerSample = expectedTaskCountPerSample
        self.finalizeProgressShare = finalizeProgressShare
    }
}

// MARK: - The lock

extension NextflowWorkflowDescriptor {
    /// The workflow's name in messages, the registry's display name of ``toolID``.
    var workflowName: String {
        AnalysisToolRegistry.displayName(forRawID: toolID.rawValue)
    }

    /// The pin `lock` holds for this workflow, its values as the lock spells them.
    ///
    /// - Throws: ``NextflowDescriptorRefusal`` with exit code 126 when `lock` has no entry for
    ///   ``lockPipelineID``, or its entry names no repository or no revision. Nothing runs then, and no
    ///   fallback revision takes the pin's place (N4).
    package func resolvePin(in lock: ManagedToolLock) throws -> NextflowPipelinePin {
        guard let spec = lock.pipeline(id: lockPipelineID),
              !spec.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !spec.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NextflowDescriptorRefusal.noPinnedVersion(of: workflowName)
        }
        return NextflowPipelinePin(spec)
    }

    /// The pin the lock bundled with LGE holds for this workflow.
    ///
    /// - Throws: ``NextflowDescriptorRefusal`` as ``resolvePin(in:)`` does.
    package func resolveBundledPin() throws -> NextflowPipelinePin {
        try resolvePin(in: .bundled)
    }

    /// The environment settings the engine adds for the pinned release, empty when the release needs
    /// none.
    package func launchEnvironment(for pin: NextflowPipelinePin) -> [String: String] {
        releaseEnvironment[pin.releaseVersion] ?? [:]
    }
}

// MARK: - The Docker wait

extension NextflowWorkflowDescriptor {
    /// Whether a launch with the effective `profile` waits for the Docker daemon before it starts.
    ///
    /// ``containerRuntime`` describes the descriptor's own ``profile``, so only a launch with exactly
    /// that profile waits. A conda run, or a stand-in run with `local`, never waits, as the TaxTriage
    /// pipeline decides today. The caller passes the profile as it normalized it.
    package func waitsForDocker(profile: String) -> Bool {
        containerRuntime == .docker && profile == self.profile
    }
}

// MARK: - The launch's arguments

extension NextflowWorkflowDescriptor {
    /// The arguments of `nextflow` for one launch, in the order the workflow's launch writes them today.
    ///
    /// The `-c` files come first, then `run` with the target, `-r` with the pin's revision for a pinned
    /// target and nothing for a snapshot, and `-resume` when the launch resumes. The profile is the
    /// launch's, or else the descriptor's, written as given. ``argumentLayout`` orders the rest, which
    /// are the samplesheet as `--input`, the output folder as `--outdir`, the trace file in the output
    /// folder when the workflow writes one, the work folder with ``workDirectoryOption`` when the launch
    /// names one, and the workflow's own options.
    package func nextflowArguments(for launch: NextflowLaunchRequest) -> [String] {
        var arguments = launch.configFiles.flatMap { ["-c", $0.path] }
        arguments.append("run")
        switch launch.target {
        case .pinned(let pin):
            arguments += [pin.repository, "-r", pin.revision]
        case .snapshot(let folder):
            arguments.append(folder.path)
        }
        if launch.resume {
            arguments.append("-resume")
        }
        let profileOption = ["-profile", launch.profile ?? profile]
        let inputAndOutput = ["--input", launch.samplesheet.path, "--outdir", launch.outputDirectory.path]
        let traceOption = traceFileName.map {
            ["-with-trace", launch.outputDirectory.appendingPathComponent($0).path]
        } ?? []
        let workOption = launch.workDirectory.map { [workDirectoryOption, $0.path] } ?? []
        switch argumentLayout {
        case .inputFirst:
            arguments += profileOption + inputAndOutput + traceOption + workOption + launch.pipelineArguments
        case .sortedParameters:
            arguments += workOption + profileOption + traceOption
            arguments += Self.sortedParameters(launch.pipelineArguments + inputAndOutput)
        }
        return arguments
    }

    /// `--name value` pairs sorted by name, as `NFCoreRunRequest` sorts its parameters.
    ///
    /// - Precondition: `arguments` alternate a name that starts with `--` and its value.
    private static func sortedParameters(_ arguments: [String]) -> [String] {
        precondition(arguments.count.isMultiple(of: 2), "Parameters come as --name value pairs")
        let pairs = stride(from: 0, to: arguments.count, by: 2).map { index in
            precondition(arguments[index].hasPrefix("--"), "A parameter's name starts with --")
            return (name: String(arguments[index].dropFirst(2)), value: arguments[index + 1])
        }
        return pairs.sorted { $0.name < $1.name }.flatMap { ["--\($0.name)", $0.value] }
    }
}

// MARK: - Pin

/// The lock's pin of one Nextflow pipeline (`PipelineSpec`), the repository with the commit or tag a run
/// passes as `-r` and the release tag a record names (R1).
package struct NextflowPipelinePin: Sendable, Equatable {
    /// The lock pipeline id, such as `taxtriage`.
    package let pipelineID: String
    /// The repository `nextflow run` fetches, such as `jhuapl-bio/taxtriage`.
    package let repository: String
    /// The commit or tag a run passes as `-r`.
    package let revision: String
    /// The release tag of the revision, such as `v3.3.8`, which a record names.
    package let releaseVersion: String

    package init(pipelineID: String, repository: String, revision: String, releaseVersion: String) {
        self.pipelineID = pipelineID
        self.repository = repository
        self.revision = revision
        self.releaseVersion = releaseVersion
    }

    /// The pin a lock entry holds, its values unchanged.
    package init(_ spec: PipelineSpec) {
        self.init(
            pipelineID: spec.id,
            repository: spec.repository,
            revision: spec.revision,
            releaseVersion: spec.releaseVersion
        )
    }
}

// MARK: - Refusal

/// Why LGE will not run a Nextflow workflow, with the code its command exits with.
///
/// A lock with no pin for the workflow refuses it at plan with
/// `LGE's tool lock has no pinned version of <W>, so LGE will not run it.` and exit 126,
/// `CLIExitCode.dependency`, the code a missing Kraken2 database exits with (N4).
package struct NextflowDescriptorRefusal: Error, LocalizedError, AnalysisRunExitCoding, Equatable, Sendable {
    /// `CLIExitCode.dependency`, equal to ``Kraken2RunRefusal/dependencyCode``.
    package static let dependencyCode: Int32 = 126

    package let message: String
    package let analysisRunExitCode: Int32

    package init(message: String, analysisRunExitCode: Int32) {
        self.message = message
        self.analysisRunExitCode = analysisRunExitCode
    }

    package var errorDescription: String? { message }

    /// The refusal of a workflow the lock has no pin for, named as people read it, such as `TaxTriage`.
    package static func noPinnedVersion(of workflowName: String) -> NextflowDescriptorRefusal {
        NextflowDescriptorRefusal(
            message: "LGE's tool lock has no pinned version of \(workflowName), so LGE will not run it.",
            analysisRunExitCode: dependencyCode
        )
    }
}

// MARK: - Container runtime

/// Whether a workflow's tasks need the Docker daemon.
package enum NextflowContainerRuntime: Sendable, Equatable {
    /// The tasks run in Docker containers, so the engine waits for the daemon before it starts.
    case docker
    /// The tasks run on the host, so nothing waits.
    case hostOnly
}

// MARK: - Argument layout

/// How a launch orders its options after `run`, the target, `-r` and `-resume`.
///
/// A run's recorded command keeps the order its launch wrote, so each workflow keeps the order it has
/// today, and moving a workflow's launch onto the descriptor changes no recorded command.
package enum NextflowArgumentLayout: Sendable, Equatable {
    /// `-profile`, `--input`, `--outdir`, the trace, the work folder, and then the workflow's options in
    /// the order the caller gives them, as the TaxTriage pipeline writes them.
    case inputFirst
    /// The work folder, `-profile` and the trace, and then every parameter as a `--name value` pair
    /// sorted by name, `--input` and `--outdir` among them, as `NFCoreRunRequest` writes them. The
    /// workflow's options must be such pairs.
    case sortedParameters
}

// MARK: - Launch

/// The run-time parts of one launch's argument list, which the descriptor puts in order, the `-c` files
/// before `run`.
package struct NextflowLaunchRequest: Sendable, Equatable {
    /// Configuration files passed with `-c`, in order, before `run`.
    package var configFiles: [URL]
    /// What `nextflow run` starts.
    package var target: NextflowLaunchTarget
    /// The samplesheet the workflow reads as `--input`.
    package var samplesheet: URL
    /// The folder the workflow writes its results into, `--outdir`.
    package var outputDirectory: URL
    /// The work folder, passed with the descriptor's ``NextflowWorkflowDescriptor/workDirectoryOption``,
    /// or nil to leave Nextflow's default.
    package var workDirectory: URL?
    /// The Nextflow profile of this launch as the caller resolved it, or nil for the descriptor's
    /// ``NextflowWorkflowDescriptor/profile``.
    package var profile: String?
    /// Whether the launch passes `-resume`, so Nextflow reuses the cached tasks of the run in its
    /// launch folder.
    package var resume: Bool
    /// The workflow's own options, which ``NextflowWorkflowDescriptor/argumentLayout`` places after
    /// LGE's options in order, or as `--name value` pairs sorted with `--input` and `--outdir`.
    package var pipelineArguments: [String]

    package init(
        configFiles: [URL] = [],
        target: NextflowLaunchTarget,
        samplesheet: URL,
        outputDirectory: URL,
        workDirectory: URL? = nil,
        profile: String? = nil,
        resume: Bool = false,
        pipelineArguments: [String] = []
    ) {
        self.configFiles = configFiles
        self.target = target
        self.samplesheet = samplesheet
        self.outputDirectory = outputDirectory
        self.workDirectory = workDirectory
        self.profile = profile
        self.resume = resume
        self.pipelineArguments = pipelineArguments
    }
}

/// What `nextflow run` starts.
package enum NextflowLaunchTarget: Sendable, Equatable {
    /// The pinned repository, which `nextflow run` fetches at the pin's revision with `-r`.
    case pinned(NextflowPipelinePin)
    /// A folder holding LGE's copy of the pinned code, exported from Nextflow's cached checkout, which
    /// `nextflow run` starts without `-r`.
    case snapshot(URL)
}
