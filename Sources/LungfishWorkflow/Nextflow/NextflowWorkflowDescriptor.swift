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
/// refuses a lock that has no pin for the workflow (decision N4), so LGE never runs a branch such as
/// `main` that no lock names.
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
    /// 1 (W3). The engine moves the bar from 0 to `1 - finalizeProgressShare`.
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
    /// The workflow's own options, in order, after LGE's.
    package var pipelineArguments: [String]

    package init(
        configFiles: [URL] = [],
        target: NextflowLaunchTarget,
        samplesheet: URL,
        outputDirectory: URL,
        workDirectory: URL? = nil,
        pipelineArguments: [String] = []
    ) {
        self.configFiles = configFiles
        self.target = target
        self.samplesheet = samplesheet
        self.outputDirectory = outputDirectory
        self.workDirectory = workDirectory
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
