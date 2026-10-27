// AnnotationDrawerIndexHandoff.swift - How a finished annotation index reaches the annotation drawer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane DRAWER (DRAWER-INDEX-HANDOFF). Two routes build the search index of a displayed bundle, the
// reload in ViewerViewController+BundleDisplay.swift and the window controller's bundleDidLoad handler in
// MainWindowController.swift. The drawer's own open and create paths hand an index that already ended to a
// drawer made later. Every one of them calls this file, so the routes cannot drift apart again, and a build
// that ends with no table to show says so in words where the drawer would otherwise read "0 annotations".
//
// Phase 3.0 lane DRAWER-ROUTE (WF-6). A drawer made while no index exists has none coming, since both routes that
// build an index assign it in the turn that makes the drawer, so it shows `noIndexYetWords` instead of reading
// "Building annotation index" for good. The building words belong to an index that is really being built.

import AppKit
import LungfishCore
import LungfishIO
import LungfishOperations

/// The words a drawer shows for an index build that ended with nothing to show, and the rule for when.
@MainActor
enum AnnotationDrawerIndexHandoff {
    /// Marks the words in the drawer's view tree, so the next handoff finds them, replaces them or removes them.
    static let noticeIdentifier = NSUserInterfaceItemIdentifier("annotationDrawerIndexNotice")

    /// The widest the words grow before they wrap onto another line.
    private static let noticeMaximumWidth: CGFloat = 520

    /// The words of a drawer that was made with no index. The next index to arrive removes or replaces them.
    static let noIndexYetWords = "No annotations to show for this view."

    /// The words for a bundle whose annotation table could not be built. They offer no Retry button, since
    /// reopening the bundle is what builds the index again.
    static func noIndexWords(bundleName: String) -> String {
        "The annotation table could not be built for \(bundleName), because its annotation database is missing "
            + "or cannot be read. Reopen the bundle, and if this repeats, import its annotations again."
    }

    /// Whether the build ended with no table to show. The manifest names an annotation database, and the
    /// finished index opened no annotation database and no variant database. A bundle with no annotation
    /// database named, or with a database that opened and holds no rows, is a legitimate empty drawer.
    static func endedWithNoIndex(_ index: AnnotationSearchIndex, bundle: ReferenceBundle) -> Bool {
        guard !index.isBuilding, index.bundleIdentifier == bundle.manifest.identifier else { return false }
        guard bundle.manifest.annotations.contains(where: { $0.databasePath != nil }) else { return false }
        return index.annotationDatabaseHandles.isEmpty && index.variantDatabaseHandles.isEmpty
    }

    /// Shows `words` centered over the drawer's table, or removes the words when `words` is nil.
    static func setNotice(_ words: String?, in drawer: AnnotationTableDrawerView) {
        let existing = drawer.subviews.first { $0.identifier == noticeIdentifier } as? NSTextField
        guard let words else {
            existing?.removeFromSuperview()
            return
        }
        if let existing {
            existing.stringValue = words
            return
        }
        let label = NSTextField(wrappingLabelWithString: words)
        label.identifier = noticeIdentifier
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = noticeMaximumWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: drawer.scrollView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: drawer.scrollView.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: drawer.scrollView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: drawer.scrollView.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: noticeMaximumWidth),
        ])
    }
}

extension ViewerViewController {
    /// The one call both routes that build an index make when the build ends. The viewer takes the index, the
    /// `annotationSearchIndex` observer hands it to a drawer that exists, and the drawer shows its words when the
    /// build left no table to show.
    func completeAnnotationIndexHandoff(_ index: AnnotationSearchIndex, for bundle: ReferenceBundle) {
        annotationSearchIndex = index
        refreshAnnotationIndexNotice(for: index, bundle: bundle)
    }

    /// The call every open, toggle and create of the drawer makes for an index that already ended, so a drawer
    /// made after the build shows the same words as a drawer that was waiting for it. An index still building is
    /// skipped, since the drawer reads its counts the moment it takes the index.
    func attachAnnotationIndexToDrawer(_ index: AnnotationSearchIndex) {
        guard let drawer = annotationDrawerView, !index.isBuilding else { return }
        drawer.setSearchIndex(index)
        refreshAnnotationIndexNotice(for: index, bundle: viewerView.currentReferenceBundle ?? currentReferenceBundle)
    }

    /// The call `configureAnnotationDrawer` makes once the new drawer is in the view tree. The drawer takes the index
    /// that exists, and an index still building leaves it in its loading state until the observer hands it over.
    /// With no index at all the drawer says so, since a build that was going to end has ended in this turn already.
    func populateCreatedAnnotationDrawer() {
        guard let drawer = annotationDrawerView else { return }
        if let index = annotationSearchIndex {
            attachAnnotationIndexToDrawer(index)
        } else {
            drawer.showNoIndexState()
        }
    }

    private func refreshAnnotationIndexNotice(for index: AnnotationSearchIndex, bundle: ReferenceBundle?) {
        guard let drawer = annotationDrawerView else { return }
        guard let bundle, AnnotationDrawerIndexHandoff.endedWithNoIndex(index, bundle: bundle) else {
            AnnotationDrawerIndexHandoff.setNotice(nil, in: drawer)
            return
        }
        AnnotationDrawerIndexHandoff.setNotice(
            AnnotationDrawerIndexHandoff.noIndexWords(bundleName: bundle.manifest.name), in: drawer
        )
    }
}

extension AnnotationTableDrawerView {
    /// The state of a drawer that no index has reached and none is building. It ends the loading state, empties the
    /// table through the entry for a drawer with no index, and shows `noIndexYetWords` where the table would be. The
    /// next index to arrive replaces all of it through `setSearchIndex` and the notice step of the handoff.
    func showNoIndexState() {
        setAnnotations([])
        AnnotationDrawerIndexHandoff.setNotice(AnnotationDrawerIndexHandoff.noIndexYetWords, in: self)
    }
}
