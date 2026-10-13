// AppDelegate+AnnotationTrackImport.swift - The Import Center's annotation track import, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The Import Center's annotation track import lives here, so that
/// AppDelegate+ImportCenter.swift, which is at its size baseline, does not
/// hold it. `importAnnotationTracksFromURLs` checks the files and the
/// project and asks for the track's identity, and
/// `performSingleAnnotationTrackImport` registers the row and attaches one
/// file to the chosen reference bundle.
extension AppDelegate {
}
