// Notifications.swift - Application-wide notification names
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Annotation Notifications

extension Notification.Name {
    /// Posted when an annotation is selected in the viewer.
    ///
    /// The notification's `object` should be the `SequenceAnnotation` that was selected,
    /// or `nil` if the selection was cleared.
    public static let annotationSelected = Notification.Name("annotationSelected")

    /// Posted when an annotation's properties have been updated.
    ///
    /// The notification's `object` should be the updated `SequenceAnnotation`.
    /// The `userInfo` dictionary may contain the key `"previousAnnotation"` with
    /// the annotation's state before the update.
    public static let annotationUpdated = Notification.Name("annotationUpdated")

    /// Posted when an annotation has been deleted.
    ///
    /// The notification's `object` should be the `SequenceAnnotation` that was deleted.
    public static let annotationDeleted = Notification.Name("annotationDeleted")

    /// Posted when a color should be applied to all annotations of a specific type.
    ///
    /// The notification's `userInfo` dictionary contains:
    /// - `annotationType`: The `AnnotationType` to update
    /// - `annotationColor`: The `AnnotationColor` to apply
    /// - `changeSource`: The source of the change (e.g., "inspector")
    public static let annotationColorAppliedToType = Notification.Name("annotationColorAppliedToType")
}

// MARK: - Appearance Notifications

extension Notification.Name {
    /// Posted when the application appearance settings have changed.
    ///
    /// This notification is posted when theme, color scheme, or other visual
    /// appearance settings are modified. Views should observe this notification
    /// to update their rendering accordingly.
    public static let appearanceChanged = Notification.Name("appearanceChanged")

    /// Posted when annotation display settings have changed.
    ///
    /// Contains userInfo keys: "showAnnotations", "annotationHeight", "annotationSpacing"
    public static let annotationSettingsChanged = Notification.Name("annotationSettingsChanged")

    /// Posted when annotation filter settings have changed.
    ///
    /// Contains userInfo keys: "visibleTypes" (Set<AnnotationType>), "filterText" (String)
    public static let annotationFilterChanged = Notification.Name("annotationFilterChanged")
}

// MARK: - Viewer Navigation Notifications

extension Notification.Name {
    /// Posted when the viewer's coordinate position changes (scroll, zoom, chromosome switch).
    ///
    /// Contains userInfo keys: "chromosome" (String), "start" (Int), "end" (Int)
    public static let viewerCoordinatesChanged = Notification.Name("viewerCoordinatesChanged")

    /// Posted when a reference bundle is loaded into the viewer.
    ///
    /// Contains userInfo keys: "bundleURL" (URL), "chromosomes" ([ChromosomeInfo])
    public static let bundleDidLoad = Notification.Name("bundleDidLoad")
}

// MARK: - Notification UserInfo Keys

/// Keys used in notification userInfo dictionaries.
public enum NotificationUserInfoKey {
    /// Key for the annotation that was selected or modified.
    public static let annotation = "annotation"

    /// Key for the previous state of an annotation before an update.
    public static let previousAnnotation = "previousAnnotation"

    /// Key for the source of a change (e.g., "inspector", "viewer", "undo").
    public static let changeSource = "changeSource"

    /// Key for the chromosome or sequence name associated with a notification.
    public static let chromosome = "chromosome"

    /// Key for the selection state associated with a notification.
    public static let selectionState = "selectionState"

    /// Key for the annotation type when applying changes to all of a type.
    public static let annotationType = "annotationType"

    /// Key for the annotation color when applying color changes.
    public static let annotationColor = "annotationColor"

    /// Key for the active sequence index in multi-sequence views.
    public static let activeSequenceIndex = "activeSequenceIndex"

    /// Key for annotation visibility state (Bool).
    public static let annotationVisible = "annotationVisible"

    /// Key for start position (Int).
    public static let start = "start"

    /// Key for end position (Int).
    public static let end = "end"

    /// Key for bundle URL.
    public static let bundleURL = "bundleURL"

    /// Key for chromosomes array.
    public static let chromosomes = "chromosomes"
}
