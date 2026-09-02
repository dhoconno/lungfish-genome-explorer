// NFCoreResourceLimits.swift - Translate resource caps for nf-core releases
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Translates Lungfish's CPU and memory caps into whatever a given nf-core
/// release understands.
///
/// Pipelines built on nf-core template 3.x (viralrecon 3.0.0 among them)
/// dropped the `--max_cpus` / `--max_memory` parameters in favour of
/// Nextflow's own `process.resourceLimits`. On such a release the old flags
/// are not merely ignored: the schema rejects unknown parameters, and every
/// process keeps its unclamped default, so a `process_high` step asks for
/// 72 GB and Nextflow aborts the run with "Process requirement exceeds
/// available memory" on any ordinary laptop. For those releases the caps are
/// written into a small config passed with `-c` instead.
enum NFCoreResourceLimits {
    /// The launch adjustments needed for one request.
    struct Plan {
        /// The request with unsupported parameters removed.
        let request: NFCoreRunRequest
        /// Config file carrying `process.resourceLimits`, when one is needed.
        let configURL: URL?

        /// Appends the `-c` flag for the generated config, if any.
        func nextflowArguments(base: [String]) -> [String] {
            guard let configURL else { return base }
            return base + ["-c", configURL.path]
        }
    }

    static let maxCPUsParameter = "max_cpus"
    static let maxMemoryParameter = "max_memory"

    /// Builds the plan, writing a config into `directory` when required.
    static func plan(for request: NFCoreRunRequest, in directory: URL) throws -> Plan {
        guard usesResourceLimits(workflow: request.workflow.name, version: request.version) else {
            return Plan(request: request, configURL: nil)
        }

        let cpus = request.params[maxCPUsParameter]?.trimmingCharacters(in: .whitespaces)
        let memory = request.params[maxMemoryParameter]?.trimmingCharacters(in: .whitespaces)
        var limits: [String] = []
        if let cpus, !cpus.isEmpty {
            limits.append("cpus: \(cpus)")
        }
        if let memory, !memory.isEmpty {
            limits.append("memory: \(memory)")
        }
        var params = request.params
        params.removeValue(forKey: maxCPUsParameter)
        params.removeValue(forKey: maxMemoryParameter)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("lungfish-resource-limits.config")
        var body = ""
        if !limits.isEmpty {
            body += """
                resourceLimits = [ \(limits.joined(separator: ", ")) ]

            """
        }
        body += Self.retryPolicy
        let contents = """
        // Written by Lungfish. This pipeline release expects Nextflow's
        // process.resourceLimits rather than --max_cpus / --max_memory.
        process {
        \(body)}

        """
        try contents.write(to: configURL, atomically: true, encoding: .utf8)

        let adjusted = NFCoreRunRequest(
            workflow: request.workflow,
            version: request.version,
            executor: request.executor,
            inputURLs: request.inputURLs,
            outputDirectory: request.outputDirectory,
            expectedOutputURLs: request.expectedOutputURLs,
            params: params,
            resume: request.resume,
            workDirectory: request.workDirectory,
            presentationMode: request.presentationMode
        )
        return Plan(request: adjusted, configURL: configURL.standardizedFileURL)
    }

    /// Retries a task that died on a status the pipeline does not expect.
    ///
    /// nf-core's base config retries only 130...145, 104 and 175, which covers
    /// signals and its own out-of-memory conventions. On Apple Silicon an
    /// amd64-only container occasionally dies during startup under emulation
    /// with some other status: QUAST has been seen exiting 3 within seconds on
    /// a consensus that a rerun processes without complaint. Nextflow's default
    /// is then to finish the run, so a transient container fault discards a
    /// pipeline that had already produced every scientific output. Retrying any
    /// non-zero status once restores those runs, and a task that fails for a
    /// real reason simply fails again on the retry.
    private static let retryPolicy = """
        // Retry once on any failure. Emulated amd64 containers die sporadically
        // during startup with statuses outside nf-core's retryable list.
        errorStrategy = { task.attempt <= 1 ? 'retry' : 'finish' }
        maxRetries = 1

    """

    /// Whether a release expects `process.resourceLimits` instead of the
    /// `--max_*` parameters. viralrecon adopted the nf-core 3.x template in 3.0.0.
    private static func usesResourceLimits(workflow: String, version: String) -> Bool {
        guard workflow == "viralrecon" else { return false }
        guard let major = Int(version.split(separator: ".").first.map(String.init) ?? "") else {
            return false
        }
        return major >= 3
    }
}
