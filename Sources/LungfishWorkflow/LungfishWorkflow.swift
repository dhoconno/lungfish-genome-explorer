// LungfishWorkflow - Workflow integration for Lungfish Genome Explorer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore

/// LungfishWorkflow provides workflow integration capabilities.
///
/// ## Overview
///
/// This module contains:
/// - **Nextflow**: Nextflow runner and schema parser
/// - **Snakemake**: Snakemake runner and config parser
/// - **VisualBuilder**: Node-based workflow graph editor
///
/// ## Key Features
///
/// - Parse `nextflow_schema.json` for native parameter UI
/// - Run workflows via `nextflow run` and `snakemake`
/// - Monitor execution progress with NSProgress
/// - Auto-import workflow outputs
/// - Support for Docker and Apptainer containers
/// - Integration with nf-core pipelines
///
/// ## Example
///
/// ```swift
/// // Run a Nextflow workflow
/// let runner = NextflowRunner()
/// let execution = try await runner.run(
///     workflow: workflowPath,
///     params: parameters,
///     profile: .docker
/// )
///
/// // Monitor progress
/// for await update in execution.progress {
///     print("Process: \(update.process), Status: \(update.status)")
/// }
/// ```
