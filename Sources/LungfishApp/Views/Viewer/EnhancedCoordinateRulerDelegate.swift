// EnhancedCoordinateRulerDelegate.swift - Delegate protocol for EnhancedCoordinateRulerView navigation callbacks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

// MARK: - Delegate Protocol

/// Delegate protocol for EnhancedCoordinateRulerView navigation callbacks.
@MainActor
public protocol EnhancedCoordinateRulerDelegate: AnyObject {

    /// Called when the user requests navigation to a specific range.
    func ruler(_ ruler: EnhancedCoordinateRulerView, didRequestNavigation start: Double, end: Double)

    /// Called when the user requests zoom-to-fit (Cmd+0).
    func rulerDidRequestZoomToFit(_ ruler: EnhancedCoordinateRulerView)

    /// Called when the user requests zoom reset (Cmd+1).
    func rulerDidRequestZoomReset(_ ruler: EnhancedCoordinateRulerView)

    /// Called when the user requests zoom in.
    func rulerDidRequestZoomIn(_ ruler: EnhancedCoordinateRulerView)

    /// Called when the user requests zoom out.
    func rulerDidRequestZoomOut(_ ruler: EnhancedCoordinateRulerView)

    /// Called when the user enters a position string in the position field.
    func ruler(_ ruler: EnhancedCoordinateRulerView, didRequestPositionInput input: String)
}
