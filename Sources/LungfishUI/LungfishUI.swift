// LungfishUI - Rendering and track system for Lungfish Genome Explorer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import AppKit

/// LungfishUI provides rendering and track visualization capabilities.
///
/// ## Overview
///
/// This module contains:
/// - **Rendering**: Core rendering infrastructure (ReferenceFrame, TileCache, RenderContext)
/// - **Tracks**: Track types and protocols (Track, DisplayMode)
/// - **Renderers**: Specialized rendering components (coming in Phase 3)
///
/// ## Key Types
///
/// - ``ReferenceFrame``: Coordinate system following IGV's model
/// - ``Track``: Protocol for track rendering
/// - ``TileCache``: Tile-based caching for efficient rendering
/// - ``DisplayMode``: Track display modes (collapsed, squished, expanded)
///
/// ## Track Types (Planned)
///
/// - ``SequenceTrack``: Reference sequence with translation frames
/// - ``FeatureTrack``: Annotation features with row packing
/// - ``AlignmentTrack``: BAM/CRAM reads with coverage
/// - ``CoverageTrack``: Signal data (BigWig)
/// - ``VariantTrack``: VCF variants
///
/// ## Example
///
/// ```swift
/// // Create a reference frame
/// let frame = ReferenceFrame(
///     chromosome: "chr1",
///     chromosomeLength: 248956422,
///     widthInPixels: 1000
/// )
///
/// // Navigate to a region
/// frame.jumpTo(start: 1000000, end: 1100000)
///
/// // Create a tile cache
/// let cache = TileCache<CGImage>(capacity: 100)
///
/// // Cache a rendered tile
/// let tileKey = TileKey(trackId: track.id, chromosome: "chr1", tileIndex: 5, zoom: 10)
/// let tile = Tile(key: tileKey, startBP: 50000, endBP: 55000, content: renderedImage)
/// await cache.set(tile, for: tileKey)
/// ```

// MARK: - Re-exports

// Note: The following types are defined in this module and available for use:
// - ReferenceFrame (Rendering/ReferenceFrame.swift)
// - TileCache, TileKey, Tile (Rendering/TileCache.swift)
// - Track, TrackDataSource, RenderContext (Tracks/Track.swift)
// - DisplayMode (Tracks/DisplayMode.swift)
// - TrackType, TrackConfiguration (Tracks/Track.swift)
