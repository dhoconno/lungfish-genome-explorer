// LungfishPlugin - Plugin system for Lungfish Genome Explorer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore

/// LungfishPlugin provides the plugin system and SDK.
///
/// ## Overview
///
/// This module contains:
/// - **Protocols**: Plugin type definitions for different plugin categories
/// - **Manager**: Plugin discovery, loading, and lifecycle management
///
/// ## Supported Plugin Languages
///
/// | Language | Use Case | Binding Method |
/// |----------|----------|----------------|
/// | Python | Data science, bioinformatics | PythonKit |
/// | Rust | High-performance algorithms | FFI via C ABI |
/// | Swift | Deep UI integration | Native |
/// | CLI | Existing tools | Process execution |
///
/// ## Plugin Categories
///
/// - ``SequenceOperationPlugin``: Transform sequences
/// - ``AnnotationGeneratorPlugin``: Generate annotations
/// - ``AssemblerPlugin``: Assembly algorithms
/// - ``AlignmentPlugin``: Alignment algorithms
/// - ``ViewerPlugin``: Custom visualization
/// - ``DatabasePlugin``: Data sources
/// - ``FormatPlugin``: Import/export formats
/// - ``WorkflowPlugin``: Workflow integration
///
/// ## Example
///
/// ```swift
/// // Swift plugin
/// @Plugin(name: "My Plugin", version: "1.0.0")
/// class MyPlugin: SequenceOperationPlugin {
///     func transform(_ sequence: Sequence) async throws -> Sequence {
///         // Transform the sequence
///     }
/// }
/// ```
