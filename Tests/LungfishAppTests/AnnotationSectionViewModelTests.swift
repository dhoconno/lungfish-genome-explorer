// AnnotationSectionViewModelTests.swift - Inspector annotation control notification tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class AnnotationSectionViewModelTests: XCTestCase {

    func testNotifySettingsChangedPostsFallbackNotificationWhenCallbackMissing() {
        let viewModel = AnnotationSectionViewModel()
        viewModel.showAnnotations = false
        viewModel.annotationHeight = 24
        viewModel.annotationSpacing = 6
        viewModel.onSettingsChanged = nil

        let expectation = expectation(forNotification: .annotationSettingsChanged, object: nil) { notification in
            guard let userInfo = notification.userInfo else { return false }
            guard let showAnnotations = userInfo["showAnnotations"] as? Bool else { return false }
            guard let annotationHeight = userInfo["annotationHeight"] as? Double else { return false }
            guard let annotationSpacing = userInfo["annotationSpacing"] as? Double else { return false }

            return showAnnotations == false && annotationHeight == 24 && annotationSpacing == 6
        }

        viewModel.notifySettingsChanged()
        wait(for: [expectation], timeout: 0.2)
    }

    func testNotifyFilterChangedPostsFallbackNotificationWhenCallbackMissing() {
        let viewModel = AnnotationSectionViewModel()
        viewModel.visibleTypes = [.gene, .cds]
        viewModel.filterText = "kinase"
        viewModel.onFilterChanged = nil

        let expectation = expectation(forNotification: .annotationFilterChanged, object: nil) { notification in
            guard let userInfo = notification.userInfo else { return false }
            guard let visibleTypes = userInfo["visibleTypes"] as? Set<AnnotationType> else { return false }
            guard let filterText = userInfo["filterText"] as? String else { return false }

            return visibleTypes == [.gene, .cds] && filterText == "kinase"
        }

        viewModel.notifyFilterChanged()
        wait(for: [expectation], timeout: 0.2)
    }

    func testToggleTypeInvokesOnFilterChangedCallbackWhenAvailable() {
        let viewModel = AnnotationSectionViewModel()
        viewModel.visibleTypes = [.gene]

        var callbackTypes: Set<AnnotationType> = []
        var callbackText = ""
        viewModel.onFilterChanged = { visibleTypes, filterText in
            callbackTypes = visibleTypes
            callbackText = filterText
        }

        viewModel.toggleType(.gene)

        XCTAssertEqual(callbackTypes, [])
        XCTAssertEqual(callbackText, "")
    }
}
