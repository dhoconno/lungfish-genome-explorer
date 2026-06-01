// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension InspectorViewController {
    // MARK: - Annotation Editing Handlers

    /// Handles annotation updates from the SelectionSection.
    ///
    /// Posts an `annotationUpdated` notification so the viewer and document
    /// can respond to the changes.
    func handleAnnotationUpdatedFromInspector(_ annotation: SequenceAnnotation) {
        viewModel.selectedAnnotation = annotation

        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector"
            ])
        )
    }

    /// Handles annotation deletion from the SelectionSection.
    ///
    /// Posts an `annotationDeleted` notification and clears the selection.
    func handleAnnotationDeletedFromInspector(_ annotationID: UUID) {
        // Get the annotation before clearing
        let deletedAnnotation = viewModel.selectedAnnotation

        // Clear selection
        viewModel.selectedAnnotation = nil

        // Post deletion notification
        if let annotation = deletedAnnotation {
            NotificationCenter.default.post(
                name: .annotationDeleted,
                object: self,
                userInfo: windowScopedUserInfo([
                    NotificationUserInfoKey.annotation: annotation,
                    NotificationUserInfoKey.changeSource: "inspector"
                ])
            )
        }
    }

    /// Handles applying a color to all annotations of a specific type.
    ///
    /// Posts an `annotationColorAppliedToType` notification so the viewer and document
    /// can update all annotations of the given type.
    func handleApplyColorToAllOfType(_ annotationType: AnnotationType, color: AnnotationColor) {
        inspectorLogger.info("handleApplyColorToAllOfType: Applying color to all \(annotationType.rawValue, privacy: .public) annotations")

        NotificationCenter.default.post(
            name: .annotationColorAppliedToType,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotationType: annotationType,
                NotificationUserInfoKey.annotationColor: color,
                NotificationUserInfoKey.changeSource: "inspector"
            ])
        )
    }

    /// Handles show/hide translation request from the Selection section.
    ///
    /// Toggles `isTranslationVisible` and posts a notification so the viewer
    /// can show or hide the CDS translation track.
    func handleShowTranslationRequested(_ annotation: SequenceAnnotation) {
        let vm = viewModel.selectionSectionViewModel
        vm.isTranslationVisible.toggle()

        NotificationCenter.default.post(
            name: .showCDSTranslationRequested,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotation: annotation,
                "visible": vm.isTranslationVisible,
            ])
        )
    }

    /// Opens add-annotation flow for the current sequence selection.
    func handleAddAnnotationRequested() {
        _ = NSApp.sendAction(#selector(AppDelegate.addAnnotation(_:)), to: nil, from: self)
    }

    /// Applies the current MSA annotation selection to the selected alignment rows.
    func handleApplyAlignmentAnnotationRequested() {
        _ = NSApp.sendAction(#selector(AppDelegate.applyAlignmentAnnotationToSelection(_:)), to: nil, from: self)
    }

    // MARK: - Appearance Handlers

    /// Handles appearance setting changes.
    ///
    /// Saves the appearance settings and posts an `appearanceChanged` notification
    /// so the viewer can update its rendering.
    func handleAppearanceChanged() {
        inspectorLogger.info("handleAppearanceChanged: Appearance change detected")

        var appearance = viewModel.appearance
        appearance.trackHeight = CGFloat(viewModel.appearanceSectionViewModel.trackHeight)
        inspectorLogger.info("handleAppearanceChanged: Track height = \(appearance.trackHeight, privacy: .public)")

        AppSettings.shared.sequenceAppearance = appearance
        AppSettings.shared.save()
        viewModel.appearance = appearance

        inspectorLogger.info("handleAppearanceChanged: Appearance persisted")
    }

    /// Handles quality overlay toggle changes.
    ///
    /// Updates appearance settings and posts notification.
    func handleQualityOverlayToggled(_ enabled: Bool) {
        var appearance = viewModel.appearance
        appearance.showQualityOverlay = enabled
        AppSettings.shared.sequenceAppearance = appearance
        AppSettings.shared.save()
        viewModel.appearance = appearance

        // AppSettings.save() posts .appearanceChanged
    }

    /// Handles sample display state changes from the SampleSection.
    ///
    /// Posts a `sampleDisplayStateChanged` notification so the viewer
    /// can update genotype row rendering.
    func handleSampleDisplayStateChanged(_ state: SampleDisplayState) {
        inspectorLogger.info("handleSampleDisplayStateChanged: showRows=\(state.showGenotypeRows) rowHeight=\(state.rowHeight) hidden=\(state.hiddenSamples.count)")

        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.sampleDisplayState: state
            ])
        )
    }

    /// Handles resetting ALL appearance settings to their defaults.
    ///
    /// This is called when the "Reset to Defaults" button is pressed in the
    /// Appearance section. It coordinates resetting all appearance-related
    /// settings across multiple section view models:
    /// - Base colors (A, T, G, C, N)
    /// - Track height
    /// - Quality overlay
    /// - Annotation height, spacing, visibility, and filters
    ///
    /// After resetting, it clears persisted settings and posts notifications
    /// so the viewer updates immediately.
    public func resetAllAppearanceSettings() {
        inspectorLogger.info("handleResetAllAppearanceSettings: Resetting ALL appearance settings to defaults")

        // 1. Reset the appearance section view model (base colors, track height)
        viewModel.appearanceSectionViewModel.resetToDefaults()

        // 2. Reset the quality section view model (quality overlay)
        viewModel.qualitySectionViewModel.resetToDefaults()

        // 3. Reset the annotation section view model (height, spacing, visibility, filters)
        viewModel.annotationSectionViewModel.resetToDefaults()

        // 4. Reset the core appearance model in AppSettings
        let defaultAppearance = SequenceAppearance.default
        AppSettings.shared.sequenceAppearance = defaultAppearance
        AppSettings.shared.save()
        viewModel.appearance = defaultAppearance
        inspectorLogger.info("handleResetAllAppearanceSettings: Reset persisted settings to defaults")

        // 5. Post annotation notifications so the viewer updates
        NotificationCenter.default.post(
            name: .annotationSettingsChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "showAnnotations": viewModel.annotationSectionViewModel.showAnnotations,
                "annotationHeight": viewModel.annotationSectionViewModel.annotationHeight,
                "annotationSpacing": viewModel.annotationSectionViewModel.annotationSpacing
            ])
        )

        // Post annotation filter changed notification
        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "visibleTypes": viewModel.annotationSectionViewModel.visibleTypes,
                "filterText": viewModel.annotationSectionViewModel.filterText
            ])
        )

        // 6. Reset bundle view state (type color overrides, navigation, etc.)
        NotificationCenter.default.post(
            name: .bundleViewStateResetRequested,
            object: self,
            userInfo: windowScopedUserInfo()
        )

        inspectorLogger.info("handleResetAllAppearanceSettings: Posted all notifications for viewer update")
    }

}
