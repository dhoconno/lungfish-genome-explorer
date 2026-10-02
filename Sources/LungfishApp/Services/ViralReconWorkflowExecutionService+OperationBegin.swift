// ViralReconWorkflowExecutionService+OperationBegin.swift - Operations panel registration for Viral Recon runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helper for the Viral Recon launch (finding R4). It lives here,
/// not beside its launch site, so the baselined
/// ViralReconWorkflowExecutionService.swift does not grow
/// (scripts/ratchets/file-size.sh).
extension ViralReconWorkflowExecutionService {
    /// Registers the Viral Recon row and returns its operation ID. The row
    /// locks `bundleURL`, the run bundle, and records the
    /// `lungfish-cli workflow run nf-core/viralrecon` command for the same
    /// request, which is the argv the process runner executes.
    ///
    /// Throws `ViralReconReportedFailure` around `OperationRefusedError`, with
    /// nothing launched, when `begin` is refused. The panel already shows the
    /// refused row, so the marker keeps `reportViralReconLaunchFailure` from
    /// adding a second failed row for the same run. Before this helper the
    /// run launched anyway after a refused start and left the refused row in
    /// place.
    ///
    /// The launch is async, so the helper returns the ID and throws on a
    /// refusal, not an `OperationStartResult` for the caller to switch on.
    static func beginViralReconOperation(
        request: ViralReconRunRequest,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared
    ) throws -> UUID {
        let result = reporter.begin(
            title: "Viral Recon",
            detail: initialDetail(for: request),
            operationType: .viralRecon,
            targetBundleURL: bundleURL,
            cliCommand: cliCommandPreview(for: request, bundleURL: bundleURL),
            routeContext: routeContext
        )
        do {
            return try result.requireStarted()
        } catch {
            throw ViralReconReportedFailure(underlying: error)
        }
    }
}
