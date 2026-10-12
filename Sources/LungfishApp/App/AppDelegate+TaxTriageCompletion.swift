// AppDelegate+TaxTriageCompletion.swift - The end of a TaxTriage run, moved out of AppDelegate+Classification.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os

/// The end of a TaxTriage launch lives here, so that AppDelegate+Classification.swift, which is at
/// its size baseline, does not hold it. `completeTaxTriageRun` builds the database and finishes the
/// row, `finishTaxTriageOperation` logs the run's warnings and moves the row to its terminal state,
/// and `writeTaxTriageCrossRefSidecars` writes the cross-reference files into the source bundles.
extension AppDelegate {
}
